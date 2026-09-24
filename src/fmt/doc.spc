// Document IR + width-aware renderer (Wadler/prettier style) for the canonical formatter. A Doc is a
// tree of layout intents; the renderer chooses flat or broken form per Group by measuring whether the
// flat form fits the remaining line width. Pool-allocated exactly like the Ast arena: DocId indices
// into a flat Vector<DocNode>, Concat children as ranges into a flat Vector<DocId>. Nodes are
// immutable once created, so DocIds may be shared (the four break kinds are single shared nodes); the
// flat width of every node is memoized AT CREATION (children always exist before parents), making
// rendering linear. A node is 16 bytes: static texts live in a side table the node indexes.

/// Index into `DocPool.docs`; 0 is the shared Nil.
pub type DocId = u32;

pub const W_INF: u32 = 0xFFFFFFFFu32; // "contains a hard break": never fits flat

/// Layout intent of one node; the trailing phrases say what `a` and `b` hold.
pub enum DocKind {
    DOC_NIL,
    DOC_TEXT_SPAN, // a: start, b: end (byte slice of the source)
    DOC_TEXT_STR, // a: index of the static text (keywords, punctuation) in `strs`
    DOC_LINE, // space when flat, break+indent when broken
    DOC_SOFTLINE, // nothing when flat, break+indent when broken
    DOC_HARDLINE, // always a break
    DOC_BLANKLINE, // always a break AND an empty line before it (preserved blank separation)
    DOC_CONCAT, // a: first child index in kids, b: child count
    DOC_INDENT, // a: child
    DOC_GROUP, // a: child
    DOC_IFBREAK, // a: 1 if a space when flat else 0, b: index in `strs` of the text when the group broke
}

/// One immutable layout node; `w` is the memoized flat width (W_INF when it can never be flat).
pub struct DocNode {
    pub kind: u8, // a DocKind
    pub a: u32,
    pub b: u32,
    pub w: u32, // memoized flat width
}

/// Arena of layout nodes for one source; also the renderer.
pub struct DocPool<'a> {
    pub docs: Vector<DocNode>,
    pub kids: Vector<DocId>,
    pub strs: Vector<str<'a>>, // static texts of DOC_TEXT_STR and DOC_IFBREAK nodes
    pub src: *const u8, // backing bytes for DOC_TEXT_SPAN
}

// The shared break nodes every pool creates after Nil (id 0).
const LINE_ID: DocId = 1;
const SOFTLINE_ID: DocId = 2;
const HARDLINE_ID: DocId = 3;
const BLANKLINE_ID: DocId = 4;

/// Columns added per DOC_INDENT level.
pub const INDENT_WIDTH: i32 = 4;

const fn wadd(x: u32, y: u32) u32 {
    if x == W_INF || y == W_INF {
        return W_INF;
    }
    return x + y;
}

struct Renderer {
    pub col: i32,
    pub width: i32,
    pub out: *mut String,
}

extend Renderer {
    fn newline(self: &mut Self, indent: i32, blank: bool) {
        // Trailing whitespace never survives a break.
        let o = unsafe &mut *self.out;
        while o.len() > 0 {
            let b = o.as_str().byte_at(o.len() - 1);
            if b != b' ' {
                break;
            }
            o.truncate(o.len() - 1);
        }
        o.push_byte(b'\n');
        if blank {
            o.push_byte(b'\n');
        }
        let mut i: i32 = 0;
        while i < indent {
            o.push_byte(b' ');
            i = i + 1;
        }
        self.col = indent;
    }
}

extend DocPool {
    /// An empty pool over `src`, the byte buffer DOC_TEXT_SPAN nodes slice. `src` must outlive the pool.
    pub fn new<'a>(src: *const u8) DocPool<'a> {
        let mut p = DocPool {
            docs: Vector::<DocNode>::new(),
            kids: Vector::<DocId>::new(),
            strs: Vector::<str>::new(),
            src: src,
        };
        // Index 0 is the shared Nil, then the shared break nodes (LINE_ID..BLANKLINE_ID).
        p.docs.push(DocNode { kind: DocKind::DOC_NIL as u8, a: 0, b: 0, w: 0 });
        p.docs.push(DocNode { kind: DocKind::DOC_LINE as u8, a: 0, b: 0, w: 1 });
        p.docs.push(DocNode { kind: DocKind::DOC_SOFTLINE as u8, a: 0, b: 0, w: 0 });
        p.docs.push(DocNode { kind: DocKind::DOC_HARDLINE as u8, a: 0, b: 0, w: W_INF });
        p.docs.push(DocNode { kind: DocKind::DOC_BLANKLINE as u8, a: 0, b: 0, w: W_INF });
        return p;
    }

    fn push(self: &mut Self, n: DocNode) DocId {
        let id = self.docs.len() as DocId;
        self.docs.push(n);
        return id;
    }

    /// The shared empty node (id 0).
    pub const fn nil(self: &Self) DocId {
        return 0;
    }

    // Store a static text and return its `strs` index.
    fn intern(self: &mut Self, s: str) u32 {
        self.strs.push(s);
        return (self.strs.len() - 1) as u32;
    }

    /// Static text (keywords, punctuation). The str must outlive the pool (string literals do).
    pub fn txt(self: &mut Self, s: str) DocId {
        let i = self.intern(s);
        return self.push(DocNode { kind: DocKind::DOC_TEXT_STR as u8, a: i, b: 0, w: s.len() as u32 });
    }

    /// A byte range of the source (identifiers, literals, comments).
    pub fn span(self: &mut Self, start: u32, end: u32) DocId {
        return self.push(DocNode { kind: DocKind::DOC_TEXT_SPAN as u8, a: start, b: end, w: end - start });
    }

    /// A space when flat, a break plus indent when the enclosing group breaks.
    pub const fn line(self: &Self) DocId {
        return LINE_ID;
    }

    /// Nothing when flat, a break plus indent when the enclosing group breaks.
    pub const fn softline(self: &Self) DocId {
        return SOFTLINE_ID;
    }

    /// An unconditional break; forces every enclosing group to break.
    pub const fn hardline(self: &Self) DocId {
        return HARDLINE_ID;
    }

    /// An unconditional break preceded by one empty line; forces every enclosing group to break.
    pub const fn blankline(self: &Self) DocId {
        return BLANKLINE_ID;
    }

    /// `child` with every break inside it indented one more level.
    pub fn indent(self: &mut Self, child: DocId) DocId {
        let w = self.docs.at(child as usize).w;
        return self.push(DocNode { kind: DocKind::DOC_INDENT as u8, a: child, b: 0, w: w });
    }

    /// A layout choice point: `child` renders flat when it fits the remaining width, else broken.
    pub fn group(self: &mut Self, child: DocId) DocId {
        let w = self.docs.at(child as usize).w;
        return self.push(DocNode { kind: DocKind::DOC_GROUP as u8, a: child, b: 0, w: w });
    }

    /// `s` when the enclosing group broke; when flat: a space if flat_space, else nothing.
    /// (Trailing comma: ifbreak(",", false). Block-vs-flat separators compose from this + Line.)
    pub fn ifbreak(self: &mut Self, s: str, flat_space: bool) DocId {
        let mut fw: u32 = 0;
        let mut fs: u32 = 0;
        if flat_space {
            fw = 1;
            fs = 1;
        }
        let i = self.intern(s);
        return self.push(DocNode { kind: DocKind::DOC_IFBREAK as u8, a: fs, b: i, w: fw });
    }

    /// Concatenate `parts[from..]` (borrowed; ids are copied out; `from` lets a caller concatenate the tail
    /// of a scratch stack). Children land contiguously in kids. No part is Nil and one part is that part
    /// itself: neither needs a node.
    pub fn concat(self: &mut Self, parts: &Vector<DocId>, from: usize) DocId {
        let n = parts.len() - from;
        if n == 0 {
            return self.nil();
        }
        if n == 1 {
            return parts[from];
        }
        let start = self.kids.len() as u32;
        let mut w: u32 = 0;
        for i in from..parts.len() {
            let c = *parts.at(i);
            self.kids.push(c);
            w = wadd(w, self.docs.at(c as usize).w);
        }
        return self.push(DocNode { kind: DocKind::DOC_CONCAT as u8, a: start, b: n as u32, w: w });
    }

    fn render_doc(self: &Self, r: &mut Renderer, id: DocId, indent: i32, flat: bool) {
        let n = *self.docs.at(id as usize);
        switch n.kind as DocKind {
            DOC_NIL => {},
            DOC_TEXT_SPAN => {
                let len = (n.b - n.a) as usize;
                unsafe (*r.out).push_bytes(unsafe (self.src + n.a as usize), len);
                r.col = r.col + len as i32;
            },
            DOC_TEXT_STR => {
                let t = self.strs[n.a as usize];
                unsafe (*r.out).push_str(t);
                r.col = r.col + t.len() as i32;
            },
            DOC_LINE => {
                if flat {
                    unsafe (*r.out).push_byte(b' ');
                    r.col = r.col + 1;
                } else {
                    r.newline(indent, false);
                }
            },
            DOC_SOFTLINE => {
                if !flat {
                    r.newline(indent, false);
                }
            },
            DOC_HARDLINE => {
                r.newline(indent, false);
            },
            DOC_BLANKLINE => {
                r.newline(indent, true);
            },
            DOC_CONCAT => {
                for i in 0..n.b {
                    self.render_doc(r, *self.kids.at((n.a + i) as usize), indent, flat);
                }
            },
            DOC_INDENT => {
                self.render_doc(r, n.a, indent + INDENT_WIDTH, flat);
            },
            DOC_GROUP => {
                // Inside a flat parent everything stays flat; otherwise break iff the flat form
                // does not fit the remaining width.
                let mut f = true;
                if !flat {
                    let rem = r.width - r.col;
                    if n.w == W_INF || n.w as i32 > rem {
                        f = false;
                    }
                }
                self.render_doc(r, n.a, indent, f);
            },
            DOC_IFBREAK => {
                if flat {
                    if n.a == 1 {
                        unsafe (*r.out).push_byte(b' ');
                        r.col = r.col + 1;
                    }
                } else {
                    let t = self.strs[n.b as usize];
                    unsafe (*r.out).push_str(t);
                    r.col = r.col + t.len() as i32;
                }
            },
        };
    }

    /// Render `root` into `out` at the given width. The result always ends with exactly one newline.
    pub fn render(self: &Self, root: DocId, width: i32, out: &mut String) {
        let mut r = Renderer { col: 0, width: width, out: out };
        self.render_doc(&mut r, root, 0, false);
        // Normalize the tail: strip trailing blank lines/spaces, end with one '\n'.
        while out.len() > 0 {
            let b = out.as_str().byte_at(out.len() - 1);
            if b != b'\n' && b != b' ' {
                break;
            }
            out.truncate(out.len() - 1);
        }
        if out.len() > 0 {
            out.push_byte(b'\n');
        }
    }
}
