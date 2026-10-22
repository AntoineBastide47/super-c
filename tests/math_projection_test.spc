// std::math::projection: the near and far depths of every perspective and infinite perspective form,
// pick_matrix and the tweaked infinite perspectives, then the default forms, every handedness and depth
// form of ortho, frustum and perspective_fov, project and unproject, the argument panics and constant
// initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::transform as *;
import std::math::projection as *;

// Every component of `a` within `eps` of `b`.
fn near<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !(a[i] - b[i]).abs().less_equal(eps) {
            return false;
        }
    }
    return true;
}

// Every column of `a` has an element farther than `eps` from `b`'s.
fn all_cols_differ<T: Float, const C: usize, const R: usize>(a: Mat<T, C, R>, b: Mat<T, C, R>, eps: T) bool {
    for i in 0..C {
        if near(a[i], b[i], eps) {
            return false;
        }
    }
    return true;
}

const fn differs(x: f32, y: f32, eps: f32) bool {
    return (x - y).abs().greater(eps);
}

// The depth of the view-space point (0, 0, z) after `p` and the division by w.
const fn depth(p: mat4, z: f32) f32 {
    let v = p * vec4::new(0.0, 0.0, z, 1.0);
    return (v / v.w()).z();
}

const ORTHO: mat4 = ortho(-2.0, 2.0, -1.0, 1.0, 0.5, 10.0);
const INFINITE: dmat4 = infinite_perspective(1.0, 1.5, 0.1);
const FOV: mat4 = perspective_fov(1.0, 640.0, 480.0, 0.1, 100.0);
const FRUSTUM: mat4 = frustum_zo(-1.0, 1.0, -1.0, 1.0, 1.0, 3.0);

@test
fn perspective_depths() {
    let near_z: f32 = 0.1;
    let far_z: f32 = 100.0;
    let eps = epsilon::<f32>();
    let fovy = pi::<f32>() * 0.25;
    let aspect: f32 = 4.0 / 3.0;
    let _ = perspective(fovy, aspect, near_z, far_z);
    let lh_zo = perspective_lh_zo(fovy, aspect, near_z, far_z);
    assert(!differs(depth(lh_zo, near_z), 0.0, eps));
    assert(!differs(depth(lh_zo, far_z), 1.0, eps));
    let lh_no = perspective_lh_no(fovy, aspect, near_z, far_z);
    assert(!differs(depth(lh_no, near_z), -1.0, eps));
    assert(!differs(depth(lh_no, far_z), 1.0, eps));
    let rh_zo = perspective_rh_zo(fovy, aspect, near_z, far_z);
    assert(!differs(depth(rh_zo, -near_z), 0.0, eps));
    assert(!differs(depth(rh_zo, -far_z), 1.0, eps));
    let rh_no = perspective_rh_no(fovy, aspect, near_z, far_z);
    assert(!differs(depth(rh_no, -near_z), -1.0, eps));
    assert(!differs(depth(rh_no, -far_z), 1.0, eps));
}

@test
fn infinite_perspective_depths() {
    let near_z: f32 = 0.1;
    let inf: f32 = 1.0e+10;
    let eps = epsilon::<f32>();
    let fovy = pi::<f32>() * 0.25;
    let aspect: f32 = 4.0 / 3.0;
    let _ = infinite_perspective(fovy, aspect, near_z);
    let lh_zo = infinite_perspective_lh_zo(fovy, aspect, near_z);
    assert(!differs(depth(lh_zo, near_z), 0.0, eps));
    assert(!differs(depth(lh_zo, inf), 1.0, eps));
    let lh_no = infinite_perspective_lh_no(fovy, aspect, near_z);
    assert(!differs(depth(lh_no, near_z), -1.0, eps));
    assert(!differs(depth(lh_no, inf), 1.0, eps));
    let rh_zo = infinite_perspective_rh_zo(fovy, aspect, near_z);
    assert(!differs(depth(rh_zo, -near_z), 0.0, eps));
    assert(!differs(depth(rh_zo, -inf), 1.0, eps));
    let rh_no = infinite_perspective_rh_no(fovy, aspect, near_z);
    assert(!differs(depth(rh_no, -near_z), -1.0, eps));
    assert(!differs(depth(rh_no, -inf), 1.0, eps));
}

@test
fn pick() {
    let p = pick_matrix(vec2::new(1.0, 2.0), vec2::new(3.0, 4.0), ivec4::new(0, 0, 320, 240));
    assert(all_cols_differ(p, mat4::diagonal(2.0), 0.001));
}

@test
fn tweaked_infinite_perspectives() {
    let a = tweaked_infinite_perspective(45.0f32, 640.0 / 480.0, 1.0);
    let b = tweaked_infinite_perspective_ep(45.0f32, 640.0 / 480.0, 1.0, 0.001);
    assert(all_cols_differ(a, mat4::identity(), 0.001));
    assert(all_cols_differ(b, mat4::identity(), 0.001));
}

@test
fn default_forms() {
    let (l, r, b, t) = (-2.0f32, 3.0f32, -1.0f32, 4.0f32);
    let (n, f) = (0.5f32, 20.0f32);
    assert(ortho(l, r, b, t, n, f) == ortho_rh_no(l, r, b, t, n, f));
    assert(ortho_zo(l, r, b, t, n, f) == ortho_rh_zo(l, r, b, t, n, f));
    assert(ortho_no(l, r, b, t, n, f) == ortho_rh_no(l, r, b, t, n, f));
    assert(ortho_lh(l, r, b, t, n, f) == ortho_lh_no(l, r, b, t, n, f));
    assert(ortho_rh(l, r, b, t, n, f) == ortho_rh_no(l, r, b, t, n, f));
    assert(frustum(l, r, b, t, n, f) == frustum_rh_no(l, r, b, t, n, f));
    assert(frustum_zo(l, r, b, t, n, f) == frustum_rh_zo(l, r, b, t, n, f));
    assert(frustum_no(l, r, b, t, n, f) == frustum_rh_no(l, r, b, t, n, f));
    assert(frustum_lh(l, r, b, t, n, f) == frustum_lh_no(l, r, b, t, n, f));
    assert(frustum_rh(l, r, b, t, n, f) == frustum_rh_no(l, r, b, t, n, f));
    assert(perspective(1.0, 1.5, n, f) == perspective_rh_no(1.0, 1.5, n, f));
    assert(perspective_zo(1.0, 1.5, n, f) == perspective_rh_zo(1.0, 1.5, n, f));
    assert(perspective_no(1.0, 1.5, n, f) == perspective_rh_no(1.0, 1.5, n, f));
    assert(perspective_lh(1.0, 1.5, n, f) == perspective_lh_no(1.0, 1.5, n, f));
    assert(perspective_rh(1.0, 1.5, n, f) == perspective_rh_no(1.0, 1.5, n, f));
    assert(perspective_fov(1.0, 640.0, 480.0, n, f) == perspective_fov_rh_no(1.0, 640.0, 480.0, n, f));
    assert(perspective_fov_zo(1.0, 640.0, 480.0, n, f) == perspective_fov_rh_zo(1.0, 640.0, 480.0, n, f));
    assert(perspective_fov_no(1.0, 640.0, 480.0, n, f) == perspective_fov_rh_no(1.0, 640.0, 480.0, n, f));
    assert(perspective_fov_lh(1.0, 640.0, 480.0, n, f) == perspective_fov_lh_no(1.0, 640.0, 480.0, n, f));
    assert(perspective_fov_rh(1.0, 640.0, 480.0, n, f) == perspective_fov_rh_no(1.0, 640.0, 480.0, n, f));
    assert(infinite_perspective(1.0, 1.5, n) == infinite_perspective_rh_no(1.0, 1.5, n));
    assert(infinite_perspective_lh(1.0, 1.5, n) == infinite_perspective_lh_no(1.0, 1.5, n));
    assert(infinite_perspective_rh(1.0, 1.5, n) == infinite_perspective_rh_no(1.0, 1.5, n));
    assert(tweaked_infinite_perspective(1.0, 1.5, n) == tweaked_infinite_perspective_ep(1.0, 1.5, n, epsilon::<f32>()));
}

@test
fn ortho_maps_the_box() {
    let p = ortho_2d(-2.0f64, 2.0, -1.0, 3.0);
    assert(p * dvec4::new(2.0, 3.0, 5.0, 1.0) == dvec4::new(1.0, 1.0, -5.0, 1.0));
    let corners = [dvec4::new(-2.0, -1.0, -0.5, 1.0), dvec4::new(2.0, 3.0, -10.0, 1.0)];
    let rh_no: dmat4 = ortho_rh_no(-2.0, 2.0, -1.0, 3.0, 0.5, 10.0);
    assert(near(rh_no * corners[0], dvec4::new(-1.0, -1.0, -1.0, 1.0), 1e-15));
    assert(near(rh_no * corners[1], dvec4::new(1.0, 1.0, 1.0, 1.0), 1e-15));
    let rh_zo: dmat4 = ortho_rh_zo(-2.0, 2.0, -1.0, 3.0, 0.5, 10.0);
    assert(near(rh_zo * corners[0], dvec4::new(-1.0, -1.0, 0.0, 1.0), 1e-15));
    assert(near(rh_zo * corners[1], dvec4::new(1.0, 1.0, 1.0, 1.0), 1e-15));
    let lh_no: dmat4 = ortho_lh_no(-2.0, 2.0, -1.0, 3.0, 0.5, 10.0);
    assert(near(lh_no * dvec4::new(-2.0, -1.0, 0.5, 1.0), dvec4::new(-1.0, -1.0, -1.0, 1.0), 1e-15));
    let lh_zo: dmat4 = ortho_lh_zo(-2.0, 2.0, -1.0, 3.0, 0.5, 10.0);
    assert(near(lh_zo * dvec4::new(2.0, 3.0, 10.0, 1.0), dvec4::new(1.0, 1.0, 1.0, 1.0), 1e-15));
}

@test
fn frustum_matches_perspective() {
    let fovy = 0.9f64;
    let aspect = 1.25f64;
    let t = 0.5 * (fovy / 2.0).tan();
    let r = t * aspect;
    assert(near_cols(frustum_rh_no(-r, r, -t, t, 0.5, 50.0), perspective_rh_no(fovy, aspect, 0.5, 50.0)));
    assert(near_cols(frustum_rh_zo(-r, r, -t, t, 0.5, 50.0), perspective_rh_zo(fovy, aspect, 0.5, 50.0)));
    assert(near_cols(frustum_lh_no(-r, r, -t, t, 0.5, 50.0), perspective_lh_no(fovy, aspect, 0.5, 50.0)));
    assert(near_cols(frustum_lh_zo(-r, r, -t, t, 0.5, 50.0), perspective_lh_zo(fovy, aspect, 0.5, 50.0)));
    let w = 640.0f64;
    let h = 512.0f64;
    let pf = perspective_fov_rh_no(fovy, w, h, 0.5, 50.0);
    assert(near_cols(pf, perspective_rh_no(fovy, w / h, 0.5, 50.0)));
    assert(near_cols(perspective_fov_rh_zo(fovy, w, h, 0.5, 50.0), perspective_rh_zo(fovy, w / h, 0.5, 50.0)));
    assert(near_cols(perspective_fov_lh_no(fovy, w, h, 0.5, 50.0), perspective_lh_no(fovy, w / h, 0.5, 50.0)));
    assert(near_cols(perspective_fov_lh_zo(fovy, w, h, 0.5, 50.0), perspective_lh_zo(fovy, w / h, 0.5, 50.0)));
}

fn near_cols(a: dmat4, b: dmat4) bool {
    for i in 0..dmat4::LEN {
        if !near(a[i], b[i], 1e-12) {
            return false;
        }
    }
    return true;
}

@test
fn project_round_trip() {
    let model = translate(rotate(dmat4::identity(), 0.3, dvec3::new(0.0, 1.0, 0.0)), dvec3::new(0.5, -1.0, -6.0));
    let viewport = ivec4::new(10, 20, 640, 480);
    let obj = dvec3::new(0.25, 0.5, -0.75);
    let no: dmat4 = perspective_rh_no(0.8, 640.0f64 / 480.0, 0.1, 100.0);
    let win = project_no(obj, model, no, viewport);
    assert(win.z() > 0.0 && win.z() < 1.0);
    assert(near(unproject_no(win, model, no, viewport), obj, 1e-9));
    assert(project(obj, model, no, viewport) == win);
    assert(unproject(win, model, no, viewport) == unproject_no(win, model, no, viewport));
    let zo: dmat4 = perspective_rh_zo(0.8, 640.0f64 / 480.0, 0.1, 100.0);
    let win_zo = project_zo(obj, model, zo, dvec4::new(10.0, 20.0, 640.0, 480.0));
    assert(near(win_zo, win, 1e-9));
    assert(near(unproject_zo(win_zo, model, zo, viewport), obj, 1e-9));
}

@test(should_panic)
fn perspective_aspect_epsilon_panics() {
    let _ = perspective(1.0, epsilon::<f32>(), 0.1, 10.0);
}

@test(should_panic)
fn perspective_fov_width_panics() {
    let _ = perspective_fov(1.0f32, 0.0, 480.0, 0.1, 10.0);
}

@test(should_panic)
fn pick_matrix_delta_panics() {
    let _ = pick_matrix(vec2::new(1.0, 2.0), vec2::new(0.0, 4.0), ivec4::new(0, 0, 320, 240));
}

@test
fn const_initializers() {
    assert(ORTHO == ortho(-2.0, 2.0, -1.0, 1.0, 0.5, 10.0));
    assert(INFINITE == infinite_perspective(1.0f64, 1.5, 0.1));
    assert(FOV == perspective_fov(1.0f32, 640.0, 480.0, 0.1, 100.0));
    assert(FRUSTUM == frustum_zo(-1.0, 1.0, -1.0, 1.0, 1.0, 3.0));
    assert(FRUSTUM[2] == vec4::new(0.0, 0.0, -1.5, -1.0));
}
