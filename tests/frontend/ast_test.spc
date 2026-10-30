// Self-hosted port of tests/ast_test.c: the node arena, the scratch-stack NodeList builder, and the type
// interner of ast::ast. Part of the selfhost/tests suite.
import ast::ast as *;
import ast::facts as facts;

// A frozen array spills past its pin; thawing folds the spill back so a later pin addresses every entry.
// The resolve frontier once thawed only two of a module's four arrays, and the next frontier's pin moved
// the split under the body nodes a `select` lowering had spilled: those nodes were then unreachable.
@test
fn split_vec_spill_thaw_and_pin_again() {
    let mut v = SplitVec::<u32>::new();
    for i in 0..100u32 {
        v.push(i);
    }
    v.freeze();
    for i in 100..1000u32 {
        v.push(i); // past the pinned capacity: the spill
    }
    assert_eq(v.len(), 1000usize);
    v.thaw();
    v.freeze();
    for i in 0..1000usize {
        assert_eq(*v.at(i), i as u32);
    }
    v.thaw();
}

// Pinning a frozen array again is a programmer error: it would move the split under the spill.
@test(should_panic)
fn split_vec_refuses_a_second_pin() {
    let mut v = SplitVec::<u32>::new();
    v.push(1u32);
    v.freeze();
    v.freeze();
}

@test
fn scratch_lists() {
    let mut a = Ast::new(8);
    let id0 = a.add(Node { kind: NODE_NONE_KIND });
    let id1 = a.add(Node { kind: NODE_NONE_KIND });
    let id2 = a.add(Node { kind: NODE_NONE_KIND });
    let id3 = a.add(Node { kind: NODE_NONE_KIND });
    // Nested mark/commit: an inner list completes while the outer is still being built.
    let outer = a.mark();
    a.push(id0);
    a.push(id1);
    let inner = a.mark();
    a.push(id2);
    a.push(id3);
    let li = a.commit(inner);
    assert_eq(li.len, 2);
    assert(unsafe a.list(li)[0] == id2 && unsafe a.list(li)[1] == id3, "inner list contents");
    let lo = a.commit(outer);
    assert_eq(lo.len, 2);
    assert(unsafe a.list(lo)[0] == id0 && unsafe a.list(lo)[1] == id1, "outer list contents");
    // Scratch fully drained after commits.
    assert_eq(a.scratch.len(), 0);
}

@test
fn interner() {
    let mut a = Ast::new(8);
    let _ = a.add(Node { kind: NODE_IDENTIFIER });
    a.init_types();
    // The concreteness cache occupies padding, not a larger Ty.
    assert_eq(sizeof(Ty), 16);
    assert(a.type_at(TYPE_NONE).kind == TypeKind::TYPE_ERROR, "slot 0 is TYPE_ERROR");
    assert_eq(Ast::builtin(BuiltinType::BT_I32), BuiltinType::BT_I32 as TypeId + 1);
    assert(a.type_at(Ast::builtin(BuiltinType::BT_I32)).kind == TypeKind::TYPE_BUILTIN, "builtin slot kind");
    let pc = Ty {
        kind: TYPE_POINTER,
        qualifier: TypeQualifier::TYPE_QUAL_CONST as u8,
        module: 0,
        as_data: TyAs { elem: Ast::builtin(BuiltinType::BT_I32) },
    };
    let pm = Ty {
        kind: TYPE_POINTER,
        qualifier: TypeQualifier::TYPE_QUAL_MUT as u8,
        module: 0,
        as_data: TyAs { elem: Ast::builtin(BuiltinType::BT_I32) },
    };
    let a1 = a.intern_type(pc);
    let a2 = a.intern_type(pc);
    let b1 = a.intern_type(pm);
    let g = a.intern_type(Ty { kind: TYPE_GENERIC, module: 0, as_data: TyAs { decl: 1 } });
    let pg = a.intern_type(Ty { kind: TYPE_POINTER, as_data: TyAs { elem: g } });
    assert(a1 == a2, "identical Ty interns to one id");
    assert(a1 != b1, "differing qualifier interns distinctly");
    assert(a.type_concrete(a1) && !a.type_concrete(g) && !a.type_concrete(pg), "concreteness is cached recursively");
}

// The per-node side tables (`mono_at`, `dyn_at`, `deref_at`) grow geometrically to the node count: a
// record once reserved the target length on top of the current one (three times the nodes here).
@test
fn node_side_tables_grow_to_the_node_count() {
    let mut a = Ast::new(8);
    let first = a.add(Node { kind: NODE_IDENTIFIER });
    let t = Ast::builtin(BuiltinType::BT_I32);
    let grow: [u32; 3] = [1000, 1000, 1];
    for g in grow {
        for _ in 0..g {
            let _ = a.add(Node { kind: NODE_IDENTIFIER });
        }
        a.set_type_args(first, &t, 1);
        a.add_dyn_use(first, t, t);
        a.add_deref_use(&DerefUse { node: first, target: t, n: 0 });
        let n = a.nodes.len();
        assert_eq(a.mono_at.len(), n);
        assert(
            a.mono_at.capacity() <= 2 * n && a.dyn_at.capacity() <= 2 * n && a.deref_at.capacity() <= 2 * n,
            "the capacity stays at most twice the nodes",
        );
    }
    assert_eq(a.mono_at[first as usize], 3u32);
    assert_eq(a.dyn_at[first as usize], 3u32);
    assert_eq(a.deref_at[first as usize], 3u32);
}

// The intern index grows geometrically: a rebuild leaves the load strictly under the trigger, so a
// run of hits at the boundary never rebuilds again (it did: about 2,000 rebuilds per transpile).
@test
fn interner_index_rebuilds_geometrically() {
    ts_init();
    let was = unsafe TS_ON;
    unsafe TS_ON = true;
    let before = ts_get(TS_INTERN_REBUILD);
    let mut a = Ast::new(8);
    let _ = a.add(Node { kind: NODE_IDENTIFIER });
    a.init_types();
    let mut last = Ast::builtin(BuiltinType::BT_I32);
    for _ in 0..3000 {
        last = a.intern_type(Ty { kind: TYPE_POINTER, as_data: TyAs { elem: last } });
        // A hit right after every insert: the boundary case that used to thrash.
        let again = a.intern_type(Ty { kind: TYPE_POINTER, as_data: TyAs { elem: a.type_at(last).as_data.elem } });
        assert(again == last, "a repeated Ty is a hit");
    }
    let rebuilds = ts_get(TS_INTERN_REBUILD) - before;
    unsafe TS_ON = was;
    assert(rebuilds <= 12, "3000 distinct types take at most log2 rebuilds");
}

// SC_TYPE_COLLIDE puts every type in one bucket: identity then rests on the full comparison alone,
// and every hit and miss answers as before.
@test
fn interner_survives_full_collisions() {
    let was = unsafe TS_COLLIDE;
    unsafe TS_COLLIDE = true;
    let mut a = Ast::new(8);
    let _ = a.add(Node { kind: NODE_IDENTIFIER });
    a.init_types();
    let seeds = a.pool.len();
    let n: usize = 200;
    let mut ids = Vector::<TypeId>::new();
    let mut last = Ast::builtin(BuiltinType::BT_I32);
    for _ in 0..n {
        last = a.intern_type(Ty { kind: TYPE_POINTER, as_data: TyAs { elem: last } });
        ids.push(last);
    }
    let mut again = Ast::builtin(BuiltinType::BT_I32);
    for i in 0..n {
        again = a.intern_type(Ty { kind: TYPE_POINTER, as_data: TyAs { elem: again } });
        assert(again == ids[i], "a repeated Ty is a hit under full collisions");
    }
    unsafe TS_COLLIDE = was;
    assert_eq(a.pool.len(), seeds + n);
}

// A module with one module-arena and one body-arena call record and one method reference.
fn facts_fixture() Ast {
    let mut a = Ast::new(8);
    let id = a.add(Node { kind: NODE_NONE_KIND });
    a.set_call_info(id, 5);
    a.set_call_info(NODE_BODY | 2, 6);
    a.push_method_ref(MethodRef { owner: id, recv: TYPE_NONE, callee: DefId { module: 0, node: id } });
    return a;
}

// SC_FACTS_CHECK holds a released table to its snapshot up to the release and to its released
// length after it, and requires each release at its point.
@test
fn facts_check_follows_the_table_releases() {
    let mut a = facts_fixture();
    let w = facts::watermark(&a);
    a.release_bodies();
    a.release_body_facts();
    assert_eq(a.call_info.len(), 1usize);
    assert_eq(facts::watermark_check(&a, &w, 0, false), 0u32);
    assert(facts::watermark_check(&a, &w, 0, true) != 0, "the checked tables are due after the checks");
    a.release_checked_tables();
    assert_eq(facts::watermark_check(&a, &w, 0, true), 0u32);

    // A write after the snapshot and before the release point is caught, though the release
    // then frees the entry it wrote.
    let mut b = facts_fixture();
    let wb = facts::watermark(&b);
    b.set_call_info(NODE_BODY | 3, 7);
    b.release_bodies();
    b.release_body_facts();
    assert_eq(facts::watermark_check(&b, &wb, 0, false), 1u32);

    let mut c = facts_fixture();
    let wc = facts::watermark(&c);
    c.push_method_ref(*c.method_refs_live().at(0));
    c.release_bodies();
    c.release_body_facts();
    c.release_checked_tables();
    assert_eq(facts::watermark_check(&c, &wc, 0, true), 1u32);

    // Bodies released without their facts break the release rule.
    let mut d = facts_fixture();
    let wd = facts::watermark(&d);
    d.release_bodies();
    assert_eq(facts::watermark_check(&d, &wd, 0, false), 1u32);
}

// A read of a released body node's facts is a programmer error.
@test(should_panic)
fn released_body_facts_refuse_a_read() {
    let mut a = facts_fixture();
    a.release_bodies();
    a.release_body_facts();
    let _ = a.call_info_of(NODE_BODY | 2);
}

@test(should_panic)
fn released_method_refs_refuse_a_write() {
    let mut a = facts_fixture();
    a.release_checked_tables();
    a.push_method_ref(MethodRef { owner: 0, recv: TYPE_NONE, callee: DefId { module: 0, node: 0 } });
}
