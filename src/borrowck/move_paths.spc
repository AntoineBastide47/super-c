// Place canonicalization and the move-path forest: one tracked node per local and per
// field/downcast chain the body actually mentions. Dereference and index projections CUT tracking --
// storage behind them is not owned by the tracked binding, so moves through them never change path
// state. Path ids are dense; sibling order is first-mention order, which is Core IR order, so two
// serial runs number identically.
import ast::ast as *;
import ir::core as ir;

pub const MP_NONE: u32 = 0xFFFFFFFF;

pub struct MovePath {
    pub base: ir::LocalId,
    pub parent: u32, // MP_NONE for a local root
    pub first_child: u32,
    pub next_sibling: u32,
    pub elem: u64, // canonical projection element under `parent` (kind << 32 | data)
    pub ty: TypeId,
}

pub struct MoveForest {
    pub paths: Vector<MovePath>,
    pub local_root: Vector<u32>, // per local: root path id (every local gets one)
    pub place_path: Vector<u32>, // per PlaceId: exact tracked path, or MP_NONE (cut by deref/index)
    pub place_cut: Vector<u32>, // per PlaceId: nearest tracked ANCESTOR path before the cut, or MP_NONE
}

extend MoveForest as Free {
    pub fn free(self: &mut Self) {
        self.paths.free();
        self.local_root.free();
        self.place_path.free();
        self.place_cut.free();
    }
}

// Field identity lives in `sub` (the field decl node; `data` is IR_NONE on member places), variant
// and index identity in `data`. Pack both under the kind tag.
const fn elem_key(kind: u8, data: u32, sub: u32) u64 {
    return kind as u64 << 56 | (data as u64 & 0xFFFFFF) << 32 | sub as u64;
}

extend MoveForest {
    pub fn empty() MoveForest {
        return MoveForest {
            paths: Vector::<MovePath>::new(),
            local_root: Vector::<u32>::new(),
            place_path: Vector::<u32>::new(),
            place_cut: Vector::<u32>::new(),
        };
    }

    pub fn build(b: &ir::CoreBody) MoveForest {
        let mut f = MoveForest::empty();
        f.build_into(b);
        return f;
    }

    pub fn build_into(self: &mut Self, b: &ir::CoreBody) {
        let f = self;
        f.paths.truncate(0);
        f.local_root.truncate(0);
        f.place_path.truncate(0);
        f.place_cut.truncate(0);
        for l in 0..b.locals.len() {
            f.paths.push(
                MovePath {
                    base: l as ir::LocalId,
                    parent: MP_NONE,
                    first_child: MP_NONE,
                    next_sibling: MP_NONE,
                    elem: 0,
                    ty: b.locals.at(l).ty,
                },
            );
            f.local_root.push(f.paths.len() as u32 - 1);
        }
        for p in 0..b.places.len() {
            let pl = *b.places.at(p);
            let mut cur = f.local_root[pl.base as usize];
            let mut cut = MP_NONE;
            for i in 0..pl.proj_len {
                let pj = *b.projections.at((pl.proj_start + i) as usize);
                if pj.kind == ir::PJ_FIELD || pj.kind == ir::PJ_DOWNCAST {
                    cur = f.child(cur, elem_key(pj.kind, pj.data, pj.sub), pj.ty, pl.base);
                } else {
                    cut = cur;
                    cur = MP_NONE;
                    break;
                }
            }
            f.place_path.push(cur);
            f.place_cut.push(cut);
        }
    }

    // The child of `parent` for canonical element `elem`, created on first mention.
    fn child(self: &mut Self, parent: u32, elem: u64, ty: TypeId, base: ir::LocalId) u32 {
        let mut c = self.paths.at(parent as usize).first_child;
        let mut last = MP_NONE;
        while c != MP_NONE {
            if self.paths.at(c as usize).elem == elem {
                return c;
            }
            last = c;
            c = self.paths.at(c as usize).next_sibling;
        }
        self.paths.push(
            MovePath { base: base, parent: parent, first_child: MP_NONE, next_sibling: MP_NONE, elem: elem, ty: ty },
        );
        let id = self.paths.len() as u32 - 1;
        if last == MP_NONE {
            self.paths[parent as usize].first_child = id;
        } else {
            self.paths[last as usize].next_sibling = id;
        }
        return id;
    }

    /// The existing child of `parent` naming field `fdecl` (member places carry field identity in
    /// `sub`), or MP_NONE when that field was never mentioned.
    pub fn field_child(self: &Self, parent: u32, fdecl: NodeId) u32 {
        let key = elem_key(ir::PJ_FIELD, ir::IR_NONE, fdecl);
        let mut c = self.paths.at(parent as usize).first_child;
        while c != MP_NONE {
            if self.paths.at(c as usize).elem == key {
                return c;
            }
            c = self.paths.at(c as usize).next_sibling;
        }
        return MP_NONE;
    }

    /// The existing child of `parent` naming positional tuple member `idx` (member places carry the
    /// index in `data` and NODE_NONE in `sub`), or MP_NONE when it was never mentioned.
    pub fn tuple_child(self: &Self, parent: u32, idx: u32) u32 {
        let key = elem_key(ir::PJ_FIELD, idx, NODE_NONE);
        let mut c = self.paths.at(parent as usize).first_child;
        while c != MP_NONE {
            if self.paths.at(c as usize).elem == key {
                return c;
            }
            c = self.paths.at(c as usize).next_sibling;
        }
        return MP_NONE;
    }

    /// Visit `p` and every descendant (iterative; `scratch` is the caller's reusable stack).
    pub fn subtree(self: &Self, p: u32, scratch: &mut Vector<u32>, out: &mut Vector<u32>) {
        out.clear();
        // Fast path for a leaf path (a scalar local, or any move path with no tracked children):
        // the subtree is just the node itself, so skip the worklist DFS. This is the common case.
        if self.paths.at(p as usize).first_child == MP_NONE {
            out.push(p);
            return;
        }
        scratch.clear();
        scratch.push(p);
        while scratch.len() != 0 {
            let cur = scratch[scratch.len() - 1];
            let _ = scratch.pop();
            out.push(cur);
            let mut c = self.paths.at(cur as usize).first_child;
            while c != MP_NONE {
                scratch.push(c);
                c = self.paths.at(c as usize).next_sibling;
            }
        }
    }
}
