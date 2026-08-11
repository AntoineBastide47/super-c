// Diagnostic trace reconstruction: turns a solver error into source-anchored lines.
// Successful bodies store no path history -- the trace re-derives what it needs from the retained
// facts, and only for the handful of errors a differential run surfaces.
import ast::ast as *;
import lexer::token as tok;
import ir::core as ir;
import module::loader as loader;
import borrowck::facts as bf;
import borrowck::loans as lo;

fn push_snip(out: &mut String, src: str, sp: tok::Span) {
    if sp.end <= sp.start || sp.end as usize > src.len() {
        out.push_str("<no source>");
        return;
    }
    let mut e = sp.end as usize;
    if e > sp.start as usize + 40 {
        e = sp.start as usize + 40;
    }
    out.push_str(src.slice(sp.start as usize, e));
}

/// One error, one line: kind, the loan's source, and the invalidating site.
pub fn render(p: &loader::Package, module: ModuleId, f: &bf::BodyFacts, e: &lo::BorrowErr) String {
    let s0 = p.modules.at(module as usize).source.as_str();
    let src = str::from_raw(s0.ptr(), s0.len());
    let mut out = String::new();
    if e.kind == lo::BE_CONFLICT {
        out.push_str("conflict: `");
        push_snip(&mut out, src, e.span);
        out.push_str("` invalidates borrow `");
        push_snip(&mut out, src, e.loan_span);
        out.push_str("`");
    } else if e.kind == lo::BE_ESCAPE {
        out.push_str("escape: borrow of local storage `");
        push_snip(&mut out, src, e.loan_span);
        out.push_str("` reaches the return");
    } else {
        out.push_str("placeholder: lifetime `");
        push_snip(&mut out, src, e.span);
        out.push_str("` flows into `");
        push_snip(&mut out, src, e.loan_span);
        out.push_str("` without a declared bound");
    }
    out.push_str(" @");
    out.push_u64(e.span.start);
    if e.loan != bf::BF_NONE && e.loan as usize < f.loans.len() {
        let lk = f.loans.at(e.loan as usize).kind;
        if lk == bf::LK_SHARED {
            out.push_str(" [shared]");
        } else if lk == bf::LK_MUT {
            out.push_str(" [mut]");
        } else {
            out.push_str(" [reserved]");
        }
    }
    return out;
}

/// A move/init error line (same shape, driver-printed).
pub fn render_move(p: &loader::Package, module: ModuleId, kind: u8, sp: tok::Span) String {
    let s0 = p.modules.at(module as usize).source.as_str();
    let src = str::from_raw(s0.ptr(), s0.len());
    let mut out = String::new();
    if kind == 0 {
        out.push_str("uninit: `");
    } else if kind == 1 {
        out.push_str("moved: `");
    } else if kind == 2 {
        out.push_str("double-move: `");
    } else {
        out.push_str("partial-move: `");
    }
    push_snip(&mut out, src, sp);
    out.push_str("` @");
    out.push_u64(sp.start);
    return out;
}
