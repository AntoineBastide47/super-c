// Document IR + width-aware renderer (Wadler/prettier style) for the canonical formatter. A Doc is a
// tree of layout intents; the renderer chooses flat or broken form per Group by measuring whether the
// flat form fits the remaining line width. Pool-allocated exactly like the Ast arena: DocId indices
// into a flat Vector<DocNode>, Concat children as ranges into a flat Vector<DocId>. Nodes are
// immutable once created, so DocIds may be shared (join() reuses one separator id); the flat width of
// every node is memoized AT CREATION (children always exist before parents), making rendering linear.

pub type DocId = u32;

pub const W_INF: u32 = 0xFFFFFFFFu32; // "contains a hard break": never fits flat

pub enum DocKind {
    DOC_NIL,
    DOC_TEXT_SPAN, // a: start, b: end -- byte slice of the source
    DOC_TEXT_STR, // s: static text (keywords, punctuation)
    DOC_LINE, // space when flat, break+indent when broken
    DOC_SOFTLINE, // nothing when flat, break+indent when broken
    DOC_HARDLINE, // always a break
    DOC_BLANKLINE, // always a break AND an empty line before it (preserved blank separation)
    DOC_CONCAT, // a: first child index in kids, b: child count
    DOC_INDENT, // a: child
    DOC_GROUP, // a: child
    DOC_IFBREAK, // s: text when the enclosing group broke, a: 1 if a space when flat else 0
}

pub struct DocNode<'a> {
    pub kind: DocKind,
    pub a: u32,
    pub b: u32,
    pub w: u32, // memoized flat width
    pub s: str<'a>,
}

pub struct DocPool<'a> {
    pub docs: Vector<DocNode<'a>>,
    pub kids: Vector<DocId>,
    pub src: *const u8, // backing bytes for DOC_TEXT_SPAN
}

pub const INDENT_WIDTH: i32 = 4;

const fn wadd(x: u32, y: u32) u32 {
    if x == W_INF || y == W_INF {
        return W_INF;
    }
    return x + y;
}

extend DocPool as Free {
    pub fn free(self: &mut Self) {
        self.docs.free();
        self.kids.free();
    }
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
    pub fn new<'a>(src: *const u8) DocPool<'a> {
        let mut p = DocPool { docs: Vector::<DocNode>::new(), kids: Vector::<DocId>::new(), src: src };
        // Index 0 is the shared Nil.
        p.docs.push(DocNode { kind: DocKind::DOC_NIL, a: 0, b: 0, w: 0, s: "" });
        return p;
    }

    fn push(self: &mut Self, n: DocNode) DocId {
        let id = self.docs.len() as DocId;
        self.docs.push(n);
        return id;
    }

    pub const fn nil(self: &Self) DocId {
        return 0;
    }

    /// Static text (keywords, punctuation). The str must outlive the pool (string literals do).
    pub fn txt(self: &mut Self, s: str) DocId {
        return self.push(DocNode { kind: DocKind::DOC_TEXT_STR, a: 0, b: 0, w: s.len() as u32, s: s });
    }

    /// A byte range of the source (identifiers, literals, comments).
    pub fn span(self: &mut Self, start: u32, end: u32) DocId {
        return self.push(DocNode { kind: DocKind::DOC_TEXT_SPAN, a: start, b: end, w: end - start, s: "" });
    }

    pub fn line(self: &mut Self) DocId {
        return self.push(DocNode { kind: DocKind::DOC_LINE, a: 0, b: 0, w: 1, s: "" });
    }

    pub fn softline(self: &mut Self) DocId {
        return self.push(DocNode { kind: DocKind::DOC_SOFTLINE, a: 0, b: 0, w: 0, s: "" });
    }

    pub fn hardline(self: &mut Self) DocId {
        return self.push(DocNode { kind: DocKind::DOC_HARDLINE, a: 0, b: 0, w: W_INF, s: "" });
    }

    pub fn blankline(self: &mut Self) DocId {
        return self.push(DocNode { kind: DocKind::DOC_BLANKLINE, a: 0, b: 0, w: W_INF, s: "" });
    }

    pub fn indent(self: &mut Self, child: DocId) DocId {
        let w = self.docs.at(child as usize).w;
        return self.push(DocNode { kind: DocKind::DOC_INDENT, a: child, b: 0, w: w, s: "" });
    }

    pub fn group(self: &mut Self, child: DocId) DocId {
        let w = self.docs.at(child as usize).w;
        return self.push(DocNode { kind: DocKind::DOC_GROUP, a: child, b: 0, w: w, s: "" });
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
        return self.push(DocNode { kind: DocKind::DOC_IFBREAK, a: fs, b: 0, w: fw, s: s });
    }

    /// Concatenate `parts` (borrowed; ids are copied out). Children land contiguously in kids.
    pub fn concat(self: &mut Self, parts: &Vector<DocId>) DocId {
        let start = self.kids.len() as u32;
        let mut w: u32 = 0;
        for i in 0..parts.len() {
            let c = *parts.at(i);
            self.kids.push(c);
            w = wadd(w, self.docs.at(c as usize).w);
        }
        return self.push(DocNode { kind: DocKind::DOC_CONCAT, a: start, b: parts.len() as u32, w: w, s: "" });
    }

    pub fn pair(self: &mut Self, a: DocId, b: DocId) DocId {
        let mut v = Vector::<DocId>::with_capacity(2);
        v.push(a);
        v.push(b);
        let d = self.concat(&v);
        return d;
    }

    fn render_doc(self: &Self, r: &mut Renderer, id: DocId, indent: i32, flat: bool) {
        let n = *self.docs.at(id as usize);
        switch n.kind {
            DOC_NIL => {},
            DOC_TEXT_SPAN => {
                let len = (n.b - n.a) as usize;
                r.out.push_bytes(unsafe (self.src + n.a as usize), len);
                r.col = r.col + len as i32;
            },
            DOC_TEXT_STR => {
                r.out.push_str(n.s);
                r.col = r.col + n.s.len() as i32;
            },
            DOC_LINE => {
                if flat {
                    r.out.push_byte(b' ');
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
                        r.out.push_byte(b' ');
                        r.col = r.col + 1;
                    }
                } else {
                    r.out.push_str(n.s);
                    r.col = r.col + n.s.len() as i32;
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
