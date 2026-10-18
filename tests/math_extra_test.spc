// std::math::extra: 32-bit integer functions, logarithms to a base, Gauss functions, gradients,
// principal component analysis, QR and RQ factorization, the 2D cross product, texture levels, `fmod` and
// bounds tests, then every form of associated min and max, the integer edges and traps, small powers,
// handedness, the covariance and eigen solver edges, every QR and RQ shape, the cross product matrices,
// row- and column-major construction, `extend_by`, `normalize_dot`, `rotate_normalized_axis` and
// constants. The module imports `std::math::all` and `std::math::extra` together.
import std::math::all as *;
import std::math::extra as *;

fn near<T: Float>(a: T, b: T, eps: T) bool {
    return (a - b).abs().less(eps);
}

fn near_vec<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !near(a[i], b[i], eps) {
            return false;
        }
    }
    return true;
}

fn near_mat<T: Float, const C: usize, const R: usize>(a: Mat<T, C, R>, b: Mat<T, C, R>, eps: T) bool {
    for i in 0..C {
        if !near_vec(a[i], b[i], eps) {
            return false;
        }
    }
    return true;
}

fn pca_epsilon<T: Float>() T {
    if sizeof(T) == 4 {
        return T::from_f32(0.00001);
    }
    return T::from_f64(0.000001);
}

const F5: i32 = factorial(5);
const P4: u32 = pow_int(3u32, 4);
const S10: i32 = sqrt_int(100);
const CROSS3: imat3 = matrix_cross3(ivec3::new(1, 2, 3));
const ROWS2: mat2 = row_major2(vec2::new(1.0, 2.0), vec2::new(3.0, 4.0));
const FLIP: imat2 = fliplr(imat2::new(1, 2, 3, 4));
const LEVELS: i32 = levels(ivec2::new(3, 2));

// The atom positions of the 1AGA agarose structure, x, y, z and a random w per point.
const AGAROSE_POINTS: usize = 126;
@fmt.skip
const AGAROSE: [f64; 504] = [
    3.219, -0.637, 19.462, 2.286,
    4.519, 0.024, 18.980, -0.828,
    4.163, 1.425, 18.481, -0.810,
    3.190, 1.341, 17.330, -0.170,
    1.962, 0.991, 18.165, 0.816,
    2.093, 1.952, 19.331, 0.276,
    5.119, -0.701, 17.908, -0.490,
    3.517, 2.147, 19.514, -0.207,
    2.970, 2.609, 16.719, 0.552,
    2.107, -0.398, 18.564, 0.403,
    2.847, 2.618, 15.335, 0.315,
    1.457, 3.124, 14.979, 0.683,
    1.316, 3.291, 13.473, 0.446,
    2.447, 4.155, 12.931, 1.324,
    3.795, 3.614, 13.394, 0.112,
    4.956, 4.494, 12.982, 0.253,
    0.483, 2.217, 15.479, 1.316,
    0.021, 3.962, 13.166, 1.522,
    2.311, 5.497, 13.395, 0.248,
    3.830, 3.522, 14.827, 0.591,
    5.150, 4.461, 11.576, 0.635,
    -1.057, 3.106, 13.132, 0.191,
    -2.280, 3.902, 12.650, 1.135,
    -3.316, 2.893, 12.151, 0.794,
    -2.756, 2.092, 11.000, 0.720,
    -1.839, 1.204, 11.835, -1.172,
    -2.737, 0.837, 13.001, -0.313,
    -1.952, 4.784, 11.578, 2.082,
    -3.617, 1.972, 13.184, 0.653,
    -3.744, 1.267, 10.389, -0.413,
    -0.709, 2.024, 12.234, -1.747,
    -3.690, 1.156, 9.005, -1.275,
    -3.434, -0.300, 8.649, 0.441,
    -3.508, -0.506, 7.143, 0.237,
    -4.822, 0.042, 6.601, -2.856,
    -5.027, 1.480, 7.064, 0.985,
    -6.370, 2.045, 6.652, 0.915,
    -2.162, -0.690, 9.149, 1.100,
    -3.442, -1.963, 6.836, -0.081,
    -5.916, -0.747, 7.065, -2.345,
    -4.965, 1.556, 8.497, 0.504,
    -6.439, 2.230, 5.246, 1.451,
    -2.161, -2.469, 6.802, -1.171,
    -2.239, -3.925, 6.320, -1.434,
    -0.847, -4.318, 5.821, 0.098,
    -0.434, -3.433, 4.670, -1.446,
    -0.123, -2.195, 5.505, 0.182,
    0.644, -2.789, 6.671, 0.865,
    -3.167, -4.083, 5.248, -0.098,
    0.101, -4.119, 6.854, -0.001,
    0.775, -3.876, 4.059, 1.061,
    -1.398, -1.625, 5.904, 0.230,
    0.844, -3.774, 2.675, 1.313,
    1.977, -2.824, 2.319, -0.112,
    2.192, -2.785, 0.813, -0.981,
    2.375, -4.197, 0.271, -0.355,
    1.232, -5.093, 0.734, 0.632,
    1.414, -6.539, 0.322, 0.576,
    1.678, -1.527, 2.819, -1.187,
    3.421, -1.999, 0.496, -1.770,
    3.605, -4.750, 0.735, 1.099,
    1.135, -5.078, 2.167, 0.854,
    1.289, -6.691, -1.084, -0.487,
    -1.057, 3.106, 22.602, -1.297,
    -2.280, 3.902, 22.120, 0.376,
    -3.316, 2.893, 21.621, 0.932,
    -2.756, 2.092, 20.470, 1.680,
    -1.839, 1.204, 21.305, 0.615,
    -2.737, 0.837, 22.471, 0.899,
    -1.952, 4.784, 21.048, -0.521,
    -3.617, 1.972, 22.654, 0.133,
    -3.744, 1.267, 19.859, 0.081,
    -0.709, 2.024, 21.704, 1.420,
    -3.690, 1.156, 18.475, -0.850,
    -3.434, -0.300, 18.119, -0.249,
    -3.508, -0.506, 16.613, 1.434,
    -4.822, 0.042, 16.071, -2.466,
    -5.027, 1.480, 16.534, -1.045,
    -6.370, 2.045, 16.122, 1.707,
    -2.162, -0.690, 18.619, -2.023,
    -3.442, -1.963, 16.336, -0.304,
    -5.916, -0.747, 16.535, 0.979,
    -4.965, 1.556, 17.967, -1.165,
    -6.439, 2.230, 14.716, 0.929,
    -2.161, -2.469, 16.302, -0.234,
    -2.239, -3.925, 15.820, -0.228,
    -0.847, -4.318, 15.321, 1.844,
    -0.434, -3.433, 14.170, 1.132,
    -0.123, -2.195, 15.005, 0.211,
    0.644, -2.789, 16.171, -0.632,
    -3.167, -4.083, 14.748, -0.519,
    0.101, -4.119, 16.354, 0.173,
    0.775, -3.876, 13.559, 1.243,
    -1.398, -1.625, 15.404, -0.187,
    0.844, -3.774, 12.175, -1.332,
    1.977, -2.824, 11.819, -1.616,
    2.192, -2.785, 10.313, 1.320,
    2.375, -4.197, 9.771, 0.237,
    1.232, -5.093, 10.234, 0.851,
    1.414, -6.539, 9.822, 1.816,
    1.678, -1.527, 12.319, -1.657,
    3.421, -1.999, 10.036, 1.559,
    3.605, -4.750, 10.235, 0.831,
    1.135, -5.078, 11.667, 0.060,
    1.289, -6.691, 8.416, 1.066,
    3.219, -0.637, 10.002, 2.111,
    4.519, 0.024, 9.520, -0.874,
    4.163, 1.425, 9.021, -1.012,
    3.190, 1.341, 7.870, -0.250,
    1.962, 0.991, 8.705, -1.359,
    2.093, 1.952, 9.871, -0.126,
    5.119, -0.701, 8.448, 0.995,
    3.517, 2.147, 10.054, 0.941,
    2.970, 2.609, 7.259, -0.562,
    2.107, -0.398, 9.104, -0.038,
    2.847, 2.618, 5.875, 0.398,
    1.457, 3.124, 5.519, 0.481,
    1.316, 3.291, 4.013, -0.187,
    2.447, 4.155, 3.471, -0.429,
    3.795, 3.614, 3.934, -0.432,
    4.956, 4.494, 3.522, -0.788,
    0.483, 2.217, 6.019, -0.923,
    0.021, 3.962, 3.636, -0.316,
    2.311, 5.497, 3.935, -1.917,
    3.830, 3.522, 5.367, -0.302,
    5.150, 4.461, 2.116, -1.615,
];

// Integer functions.

@test
fn integer_nlz() {
    for i in 1u32..33 {
        assert_eq(nlz(i), 31 - find_msb(i) as u32);
    }
}

@test
fn integer_log2() {
    for i in 1..24 {
        let a = log2_int(1u32 << i as u32);
        let b = ((1u32 << i as u32) as f64).log2() as u32;
        assert((a as f64 - b as f64).abs() <= 24.0);
        assert_eq(a, i as u32);
    }
}

@test
fn integer_pow_uint() {
    assert_eq(pow_int(2u32, 0), 1u32);
    assert_eq(pow_int(2u32, 1), 2u32);
    assert_eq(pow_int(2u32, 2), 4u32);
}

@test
fn integer_pow_int() {
    assert_eq(pow_int(2, 0), 1);
    assert_eq(pow_int(2, 1), 2);
    assert_eq(pow_int(2, 2), 4);
    assert_eq(pow_int(-2, 0), -1);
    assert_eq(pow_int(-2, 1), -2);
    assert_eq(pow_int(-2, 2), 4);
}

// Logarithm to a base.

@test
fn log_base_run() {
    assert(near(log_base(10.0f32, 2.0), 10.0f32.log2(), 0.00001));
    assert(near_vec(log_base(vec1::splat(10.0), vec1::splat(2.0)), log2(vec1::splat(10.0)), 0.00001));
    assert(near_vec(log_base(vec2::splat(10.0), vec2::splat(2.0)), log2(vec2::splat(10.0)), 0.00001));
    assert(near_vec(log_base(vec3::splat(10.0), vec3::splat(2.0)), log2(vec3::splat(10.0)), 0.00001));
    assert(near_vec(log_base(vec4::splat(10.0), vec4::splat(2.0)), log2(vec4::splat(10.0)), 0.00001));
}

// Gauss functions, checked against the density formula.

@test
fn functions_gauss_1d() {
    for i in 0..20 {
        let x = i as f32 * 0.1;
        let g = gauss(x, 0.0, 1.0);
        assert(near(g, (-(x * x) / 2.0).exp() / 6.2831853f32.sqrt(), 0.000001));
    }
}

@test
fn functions_gauss_2d() {
    for i in 0..20 {
        let x = i as f32 * 0.1;
        let g = gauss(vec2::splat(i as f32) * 0.1, vec2::splat(0.0), vec2::splat(1.0));
        let s = x * x / 2.0;
        assert(near(g, (-(s + s)).exp(), 0.000001));
    }
}

// Gradients.

@test
fn gradient_paint_radial() {
    let g = radial_gradient(vec2::splat(0.0), 1.0f32, vec2::splat(1.0), vec2::splat(0.5));
    assert(g != 0.0);
}

@test
fn gradient_paint_linear() {
    let g = linear_gradient(vec2::splat(0.0), vec2::splat(1.0), vec2::splat(0.5));
    assert(g != 0.0);
    assert_eq(g, 0.5f32);
}

// Principal component analysis.

// The center of gravity, summed in f64.
fn compute_center<T: Float, const N: usize>(data: []Vec<T, N>) Vec<T, N> {
    let mut c = [0.0f64; N];
    for p in data {
        for d in 0..N {
            unsafe {
                c[d] += p[d].cast::<f64>();
            }
        }
    }
    let mut r = Vec::<T, N>::zero();
    for d in 0..N {
        unsafe {
            r[d] = T::from_f64(c[d] / data.len() as f64);
        }
    }
    return r;
}

// The agarose points, the first N coordinates of each.
fn agarose_points<T: Float, const N: usize>() Vector<Vec<T, N>> {
    let mut v = Vector::<Vec<T, N>>::new();
    for i in 0..AGAROSE_POINTS {
        let mut p = Vec::<T, N>::zero();
        for d in 0..N {
            p[d] = T::from_f64(unsafe AGAROSE[i * 4 + d]);
        }
        v.push(p);
    }
    return v;
}

const EXPECTED_COVAR: dmat4 = dmat4::new(
    9.62434068027210898322,
    -0.00006657369614512471,
    -4.29321376568405099761,
    0.01879374187452758846,
    -0.00006657369614512471,
    9.62443937868480681175,
    5.35113872637944076871,
    -0.11569259145880574080,
    -4.29321376568405099761,
    5.35113872637944076871,
    35.62848549634668415820,
    0.90874239254220201545,
    0.01879374187452758846,
    -0.11569259145880574080,
    0.90874239254220201545,
    1.09705971856890904803,
);
const EVALS2: dvec2 = dvec2::new(
    9.62447289926297399961763301774251330057894539467032275382255,
    9.62430715969394210015560961264297422776572580714373620309355,
);
const EVALS3: dvec3 = dvec3::new(
    37.3274494274683425233695502581182052836449738530676689472257,
    9.62431434161498823505729817436585077939509766554969096873168,
    7.92550178622027216422369326567668971675332732240052872097887,
);
const EVALS4: dvec4 = dvec4::new(
    37.3477389918792213596879452204499702406947817221901007885630,
    9.62470688921105696017807313860277172063600080413412567999700,
    7.94017075281634999342344275928070533134615133171969063657713,
    1.06170863996588365446060186982477896078741484440002343404155,
);
const EVECS2: dmat2 = dmat2::new(
    -0.503510847492551904906870957742619139443409162857537237123308,
    1.0,
    1.98605453086051402895741763848787613048533838388005162794043,
    1.0,
);
const EVECS3: dmat3 = dmat3::new(
    -0.154972738414395866005286433008304444294405085038689821864654,
    0.193161285869815165989799191097521722568079378840201629578695,
    1.0,
    -158565.112775416943154745839952575022429933119522746586149868,
    -127221.506282351944358932458687410410814983610301927832439675,
    1.0,
    2.52702248596556806145700361724323960543858113426446460406536,
    -3.14959802931313870497377546974185300816008580801457419079412,
    1.0,
);
const EVECS4: dmat4 = dmat4::new(
    -6.35322390281037045217295803597357821705371650876122113027264,
    7.91546394153385394517767054617789939529794642646629201212056,
    41.0301543819240679808549819457450130787045236815736490549663,
    1.0,
    -114.622418941087829756565311692197154422302604224781253861297,
    -92.2070185807065289900871215218752013659402949497379896153118,
    0.0155846091025912430932734548933329458404665760587569100867246,
    1.0,
    13.1771887761559019483954743159026938257325190511642952175789,
    -16.3688257459634877666638419310116970616615816436949741766895,
    5.17386502341472097227408249233288958059579189051394773143190,
    1.0,
    -0.0192777078948229800494895064532553117703859768210647632969276,
    0.0348034950916108873629241563077465542944938906271231198634442,
    -0.0340715609308469289267379681032545422644143611273049912226126,
    1.0,
);

// Every permutation of four values and their vectors sorts back.
fn eigenvalue_sort_case<T: Float, const N: usize>() bool {
    let permutations: [[usize; 4]; 24] = [
        [0, 1, 2, 3],
        [1, 0, 2, 3],
        [0, 2, 1, 3],
        [1, 2, 0, 3],
        [2, 0, 1, 3],
        [2, 1, 0, 3],
        [0, 1, 3, 2],
        [1, 0, 3, 2],
        [0, 2, 3, 1],
        [1, 2, 3, 0],
        [2, 0, 3, 1],
        [2, 1, 3, 0],
        [0, 3, 1, 2],
        [1, 3, 0, 2],
        [0, 3, 2, 1],
        [1, 3, 2, 0],
        [2, 3, 0, 1],
        [2, 3, 1, 0],
        [3, 0, 1, 2],
        [3, 1, 0, 2],
        [3, 0, 2, 1],
        [3, 1, 2, 0],
        [3, 2, 0, 1],
        [3, 2, 1, 0],
    ];
    let counts: [usize; 5] = [0, 1, 2, 6, 24];
    let ref_val = Vec::<T, 4>::new(T::from_i64(10), T::from_i64(8), T::from_i64(6), T::from_i64(4)).truncate::<N>();
    let ref_vec = Mat::<T, N, N>::from_mat(
        Mat::<f64, 4, 4>::new(10.0, 20.0, 5.0, 40.0, 8.0, 16.0, 4.0, 32.0, 6.0, 12.0, 3.0, 24.0, 4.0, 8.0, 2.0, 16.0).cast::<
            T
        >(),
    );
    let eps = pca_epsilon::<T>();
    for p in 0..unsafe counts[N] {
        let mut val = ref_val;
        let mut vecs = ref_vec;
        for i in 0..N {
            let k = unsafe permutations[p][i];
            val[i] = ref_val[k];
            vecs[i] = ref_vec[k];
        }
        let (sv, sm) = sort_eigenvalues(val, vecs);
        if !near_vec(sv, ref_val, eps) || !near_mat(sm, ref_vec, eps) {
            return false;
        }
    }
    return true;
}

// The agarose covariance, then the variants agree on random data.
fn covar_case<T: Float + LinearRand, const N: usize>(size: usize, seed: u64) bool {
    let eps = pca_epsilon::<T>();
    let data = agarose_points::<T, N>();
    let center = compute_center(data[0..data.len()]);
    let covar = compute_covariance_matrix_with_center(data[0..data.len()], center);
    if !near_mat(covar, Mat::<f64, N, N>::from_mat(EXPECTED_COVAR).cast::<T>(), eps) {
        return false;
    }
    let mut rng = Pcg32::new(seed, 54);
    let mut offset = Vec::<T, N>::zero();
    for d in 0..N {
        offset[d] = gauss_rand(&mut rng, T::zero(), T::one());
    }
    let mut points = Vector::<Vec<T, N>>::new();
    for _ in 0..size {
        let mut p = offset;
        for d in 0..N {
            p[d] = offset[d] + gauss_rand(&mut rng, T::zero(), T::one());
        }
        points.push(p);
    }
    let c = compute_center(points[0..size]);
    let mut centered = Vector::<Vec<T, N>>::new();
    let mut reversed = Vector::<Vec<T, N>>::new();
    for i in 0..size {
        centered.push(*points.at(i) - c);
        reversed.push(*points.at(size - 1 - i));
    }
    let c1 = compute_covariance_matrix(centered[0..size]);
    let c3 = compute_covariance_matrix_with_center(points[0..size], c);
    let c4 = compute_covariance_matrix_with_center(reversed[0..size], c);
    return near_mat(c1, c3, eps) && near_mat(c1, c4, eps);
}

// The eigen pairs of the agarose covariance against the reference.
fn eigenvectors_case<T: Float, const N: usize>(values: Vec<f64, N>, vectors: Mat<f64, N, N>, eps: T) bool {
    let covar = Mat::<f64, N, N>::from_mat(EXPECTED_COVAR).cast::<T>();
    let (count, ev, evec) = find_eigenvalues_sym_real(covar);
    if count != N as u32 {
        return false;
    }
    let (sv, sm) = sort_eigenvalues(ev, evec);
    if !near_vec(sv, values.cast::<T>(), eps) {
        return false;
    }
    let expected = vectors.cast::<T>();
    for i in 0..N {
        let act = normalize(sm[i]);
        let mut exp = normalize(expected[i]);
        if act[0].less(T::zero()) != exp[0].less(T::zero()) {
            exp = -exp;
        }
        if !near_vec(act, exp, eps) {
            return false;
        }
    }
    return true;
}

// The principal axes of a point pattern in a random orthonormal frame.
fn rnd_case(seed: u64) bool {
    let mut rng = Pcg32::new(seed, 54);
    let eps = 0.000001f64;
    let x = normalize(gauss_rand(&mut rng, dvec3::zero(), dvec3::splat(1.0)));
    let mut y0 = gauss_rand(&mut rng, dvec3::zero(), dvec3::splat(1.0));
    for _ in 0..16 {
        if dot(x, y0).abs() >= eps {
            break;
        }
        y0 = gauss_rand(&mut rng, dvec3::zero(), dvec3::splat(1.0));
    }
    let z = normalize(cross(x, normalize(y0)));
    let y = normalize(cross(z, x));
    let pattern: [f64; 12] = [8.0, 0.0, 0.0, 4.0, 1.0, 2.0, 0.0, 2.0, 0.0, 0.0, 0.0, 4.0];
    let offset = gauss_rand(&mut rng, dvec3::zero(), dvec3::splat(1.0));
    let mut points = Vector::<dvec3>::new();
    for p in 0..4 {
        for xs in [1.0f64, -1.0] {
            for ys in [1.0f64, -1.0] {
                for zs in [1.0f64, -1.0] {
                    let (a, b, c) = unsafe (pattern[p * 3], pattern[p * 3 + 1], pattern[p * 3 + 2]);
                    points.push(offset + x * (a * xs) + y * (b * ys) + z * (c * zs));
                }
            }
        }
    }
    let center = compute_center(points[0..points.len()]);
    let covar = compute_covariance_matrix_with_center(points[0..points.len()], center);
    let (count, ev, evec) = find_eigenvalues_sym_real(covar);
    if count != 3 {
        return false;
    }
    let (_, sm) = sort_eigenvalues(ev, evec);
    let mut e = sm;
    if e[0][0].less(0.0) != x[0].less(0.0) {
        e[0] = -e[0];
    }
    if e[2][0].less(0.0) != y[0].less(0.0) {
        e[2] = -e[2];
    }
    if e[1][0].less(0.0) != z[0].less(0.0) {
        e[1] = -e[1];
    }
    return near_vec(x, e[0], eps) && near_vec(y, e[2], eps) && near_vec(z, e[1], eps);
}

@test
fn pca_smoke_test() {
    let mut points = Vector::<vec3>::new();
    for x in -5..=5 {
        for y in -7..=7 {
            for z in -3..=3 {
                points.push(vec3::new(x as f32, y as f32, z as f32));
            }
        }
    }
    let covar = compute_covariance_matrix(points[0..points.len()]);
    let (count, ev, evec) = find_eigenvalues_sym_real(covar);
    assert_eq(count, 3u32);
    let (_, sm) = sort_eigenvalues(ev, evec);
    assert(near_vec(abs(sm[0]), vec3::new(0.0, 1.0, 0.0), 0.00001));
    assert(near_vec(abs(sm[1]), vec3::new(1.0, 0.0, 0.0), 0.00001));
    assert(near_vec(abs(sm[2]), vec3::new(0.0, 0.0, 1.0), 0.00001));
}

@test
fn pca_eigenvalue_sort() {
    assert(eigenvalue_sort_case::<f32, 2>());
    assert(eigenvalue_sort_case::<f64, 2>());
    assert(eigenvalue_sort_case::<f32, 3>());
    assert(eigenvalue_sort_case::<f64, 3>());
    assert(eigenvalue_sort_case::<f32, 4>());
    assert(eigenvalue_sort_case::<f64, 4>());
}

@test
fn pca_covar() {
    assert(covar_case::<f32, 2>(100, 12345));
    assert(covar_case::<f64, 2>(100, 42));
    assert(covar_case::<f32, 3>(100, 2021));
    assert(covar_case::<f64, 3>(100, 815));
    assert(covar_case::<f32, 4>(100, 3141));
    assert(covar_case::<f64, 4>(100, 174));
}

@test
fn pca_eigenvectors() {
    assert(eigenvectors_case(EVALS2, EVECS2, 0.002f32));
    assert(eigenvectors_case(EVALS2, EVECS2, 0.00000000001f64));
    assert(eigenvectors_case(EVALS3, EVECS3, 0.00001f32));
    assert(eigenvectors_case(EVALS3, EVECS3, 0.0000000001f64));
    assert(eigenvectors_case(EVALS4, EVECS4, 0.0001f32));
    assert(eigenvectors_case(EVALS4, EVECS4, 0.0000001f64));
}

@test
fn pca_rnd_test() {
    assert(rnd_case(12345));
    assert(rnd_case(42));
}

// Matrix factorization.

// The error count of q * r against m, of q's orthonormal columns and r's lower part.
fn qr_errors<const C: usize, const R: usize, const K: usize>(m: Mat<f64, C, R>, q: Mat<f64, K, R>, r: Mat<f64, C, K>) i32 {
    let eps = 1e-10f64;
    let mut errors = 0;
    let err = q * r - m;
    for i in 0..C {
        for j in 0..R {
            if err[i][j].abs() > eps {
                errors += 1;
            }
        }
    }
    for i in 0..K {
        if length(q[i]) - 1.0 > eps {
            errors += 1;
        }
        for j in 0..i {
            if dot(q[i], q[j]).abs() > eps {
                errors += 1;
            }
        }
    }
    for i in 0..C {
        for j in i + 1..K {
            if !near(r[i][j], 0.0, epsilon::<f64>()) {
                errors += 1;
            }
        }
    }
    return errors;
}

// The error count of r * q against m, of q's orthonormal rows and r's lower part.
fn rq_errors<const C: usize, const R: usize, const K: usize>(m: Mat<f64, C, R>, r: Mat<f64, K, R>, q: Mat<f64, C, K>) i32 {
    let eps = 1e-10f64;
    let mut errors = 0;
    let err = r * q - m;
    for i in 0..C {
        for j in 0..R {
            if err[i][j].abs() > eps {
                errors += 1;
            }
        }
    }
    let tq = transpose(q);
    for i in 0..K {
        if length(tq[i]) - 1.0 > eps {
            errors += 1;
        }
        for j in 0..i {
            if dot(tq[i], tq[j]).abs() > eps {
                errors += 1;
            }
        }
    }
    for i in 0..K {
        for j in R - K + i + 1..R {
            if !near(r[i][j], 0.0, epsilon::<f64>()) {
                errors += 1;
            }
        }
    }
    return errors;
}

@test
fn matrix_factorisation_qr() {
    let m3 = dmat3::new(12.0, 6.0, -4.0, -51.0, 167.0, 24.0, 4.0, -68.0, -41.0);
    let (q3, r3) = qr_decompose(m3);
    assert_eq(qr_errors(m3, q3, r3), 0);
    let m34 = dmat3x4::new(12.0, 6.0, -4.0, -51.0, 167.0, 24.0, 4.0, -68.0, -41.0, 7.0, 2.0, 15.0);
    let (q34, r34) = qr_decompose(m34);
    assert_eq(qr_errors(m34, q34, r34), 0);
    let m43 = dmat4x3::new(12.0, 6.0, -4.0, -51.0, 167.0, 24.0, 4.0, -68.0, -41.0, 7.0, 2.0, 15.0);
    let (q43, r43) = qr_decompose(m43);
    assert_eq(qr_errors(m43, q43, r43), 0);
}

@test
fn matrix_factorisation_rq() {
    let m3 = dmat3::new(12.0, 6.0, -4.0, -51.0, 167.0, 24.0, 4.0, -68.0, -41.0);
    let (r3, q3) = rq_decompose(m3);
    assert_eq(rq_errors(m3, r3, q3), 0);
    let m34 = dmat3x4::new(12.0, 6.0, -4.0, -51.0, 167.0, 24.0, 4.0, -68.0, -41.0, 7.0, 2.0, 15.0);
    let (r34, q34) = rq_decompose(m34);
    assert_eq(rq_errors(m34, r34, q34), 0);
    let m43 = dmat4x3::new(12.0, 6.0, -4.0, -51.0, 167.0, 24.0, 4.0, -68.0, -41.0, 7.0, 2.0, 15.0);
    let (r43, q43) = rq_decompose(m43);
    assert_eq(rq_errors(m43, r43, q43), 0);
}

// 2D cross product.

@test
fn exterior_product_cross() {
    let f = cross_2d(vec2::new(1.0, 1.0), vec2::new(1.0, 1.0));
    assert(near(f, 0.0, 0.001));
    assert_eq(cross_2d(dvec2::new(1.0, 2.0), dvec2::new(3.0, 4.0)), -2.0);
}

// Texture levels.

@test
fn texture_levels() {
    assert_eq(levels(ivec2::new(3, 2)), 2);
}

// `fmod`, `isdenormal` and bounds tests.

fn mod_trunc(a: f32, b: f32) f32 {
    return a - b * (a / b).trunc();
}

@test
fn common_fmod() {
    assert((fmod(3.0f32, 2.0) - 1.0).abs() < 0.00001);
    assert(all(epsilon_equal(fmod(vec4::splat(3.0), 2.0), vec4::splat(1.0), 0.00001)));
    assert(all(epsilon_equal(fmod(vec4::splat(3.0), vec4::splat(2.0)), vec4::splat(1.0), 0.00001)));
    assert(all(equal(fmod(ivec4::splat(3), 2), ivec4::splat(1))));
    assert(all(equal(fmod(ivec4::splat(3), ivec4::splat(2)), ivec4::splat(1))));
    assert((fmod(22.0f32, -10.0) - 2.0).abs() < 0.00001);
    assert(all(epsilon_equal(fmod(vec4::splat(22.0), -10.0), vec4::splat(2.0), 0.00001)));
    assert(all(epsilon_equal(fmod(vec4::splat(22.0), vec4::splat(-10.0)), vec4::splat(2.0), 0.00001)));
    assert(all(equal(fmod(ivec4::splat(22), -10), ivec4::splat(2))));
    assert(all(equal(fmod(ivec4::splat(22), ivec4::splat(-10)), ivec4::splat(2))));
    let mut y = -10.0f32;
    while y < 10.0 {
        let mut x = -10.0f32;
        while x < 10.0 {
            let a = x.fmod(y);
            assert(epsilon_equal(a, fmod(x, y), 0.0001));
            assert(epsilon_equal(a, mod_trunc(x, y), 0.00001));
            x += 0.1;
        }
        y += 0.1;
    }
}

@test
fn common_isdenormal() {
    assert(!isdenormal(1.0f32));
    assert(!any(isdenormal(vec1::splat(1.0))));
    assert(!any(isdenormal(vec2::splat(1.0))));
    assert(!any(isdenormal(vec3::splat(1.0))));
    assert(!any(isdenormal(vec4::splat(1.0))));
}

@test
fn common_open_bounded() {
    assert(all(open_bounded(ivec2::splat(2), ivec2::splat(1), ivec2::splat(3))));
    assert(!all(open_bounded(ivec2::splat(1), ivec2::splat(1), ivec2::splat(3))));
    assert(!all(open_bounded(ivec2::splat(3), ivec2::splat(1), ivec2::splat(3))));
}

@test
fn common_close_bounded() {
    assert(all(close_bounded(ivec2::splat(2), ivec2::splat(1), ivec2::splat(3))));
    assert(all(close_bounded(ivec2::splat(1), ivec2::splat(1), ivec2::splat(3))));
    assert(all(close_bounded(ivec2::splat(3), ivec2::splat(1), ivec2::splat(3))));
}

// Every form and edge case.

@test
fn imports_all_and_extra_together() {
    let x = vec3::new(1.0, 2.0, 2.0);
    let y = vec3::new(2.0, -1.0, 0.5);
    let n = dot(normalize(x), normalize(y));
    assert(near(normalize_dot(x, y), n, 0.000001));
    let axis = normalize(vec3::new(1.0, 1.0, 0.0));
    let r = rotate(mat4::identity(), 0.75f32, axis);
    let s = rotate_normalized_axis(mat4::identity(), 0.75f32, axis);
    assert(near_mat(r, s, 0.000001));
}

@test
fn associated_scalar_keys_scalar_values() {
    assert_eq(associated_min(1.0, 10, 2.0, 20), 10);
    assert_eq(associated_min(3.0, 10, 2.0, 20), 20);
    assert_eq(associated_max(1.0, 10, 2.0, 20), 20);
    assert_eq(associated_max(3, true, 2, false), true);
    assert_eq(associated_min3(3, 10u8, 2, 20, 1, 30), 30u8);
    assert_eq(associated_min3(1u8, 1.5, 2, 2.5, 3, 3.5), 1.5);
    assert_eq(associated_max3(1.0, 1, 3.0, 2, 2.0, 3), 2);
    assert_eq(associated_min4(4, 1, 3, 2, 2, 3, 1, 4), 4);
    assert_eq(associated_max4(4, 1, 3, 2, 2, 3, 1, 4), 1);
    // A NaN key loses each comparison: the result is the second value of the pair.
    let nan = f32::nan();
    assert_eq(associated_min(nan, 1, 0.0, 2), 2);
    assert_eq(associated_max(nan, 1, 0.0, 2), 2);
    assert_eq(associated_min(0.0, 1, nan, 2), 2);
}

@test
fn associated_vector_keys_vector_values() {
    let x = vec3::new(1.0, 5.0, 3.0);
    let y = vec3::new(2.0, 4.0, 3.0);
    let a = ivec3::new(10, 11, 12);
    let b = ivec3::new(20, 21, 22);
    assert_eq(associated_min(x, a, y, b), ivec3::new(10, 21, 22));
    assert_eq(associated_max(x, a, y, b), ivec3::new(20, 11, 22));
    let z = vec3::new(0.0, 6.0, 1.0);
    let c = ivec3::new(30, 31, 32);
    assert_eq(associated_min3(x, a, y, b, z, c), ivec3::new(30, 21, 32));
    assert_eq(associated_max3(x, a, y, b, z, c), ivec3::new(20, 31, 22));
    let w = vec3::new(9.0, -1.0, 2.0);
    let d = ivec3::new(40, 41, 42);
    assert_eq(associated_min4(x, a, y, b, z, c, w, d), ivec3::new(30, 41, 32));
    assert_eq(associated_max4(x, a, y, b, z, c, w, d), ivec3::new(40, 31, 22));
    let bools = associated_min(
        vec2::new(1.0, 2.0),
        bvec2::new(true, true),
        vec2::new(2.0, 1.0),
        bvec2::new(false, false),
    );
    assert_eq(bools, bvec2::new(true, false));
}

@test
fn associated_scalar_keys_vector_values() {
    let a = vec2::new(1.5, 2.5);
    let b = vec2::new(3.5, 4.5);
    assert_eq(associated_min(1.0, a, 2.0, b), a);
    assert_eq(associated_min3(3.0, a, 2.0, b, 1.0, vec2::splat(9.0)), vec2::splat(9.0));
    assert_eq(associated_min4(1, a, 2, b, 0, vec2::splat(7.0), 5, vec2::splat(8.0)), vec2::splat(7.0));
    assert_eq(associated_max4(1, a, 2, b, 0, vec2::splat(7.0), 5, vec2::splat(8.0)), vec2::splat(8.0));
    // The 2- and 3-pair max return a vector of the key type.
    let m: ivec2 = associated_max(3, a, 2, b);
    assert_eq(m, ivec2::new(1, 2));
    let m3: dvec2 = associated_max3(1.0f64, ivec2::new(7, 8), 2.0, ivec2::new(5, 6), 0.0, ivec2::new(3, 4));
    assert_eq(m3, dvec2::new(5.0, 6.0));
}

@test
fn associated_vector_keys_scalar_values() {
    let x = vec2::new(1.0, 5.0);
    let y = vec2::new(2.0, 4.0);
    assert_eq(associated_min(x, 10, y, 20), ivec2::new(10, 20));
    assert_eq(associated_max(x, 10, y, 20), ivec2::new(20, 10));
    // The 3-pair min of this form follows the vector form.
    assert_eq(associated_min3(x, 10, y, 20, vec2::new(0.0, 9.0), 30), ivec2::new(30, 20));
    assert_eq(associated_max3(x, 10, y, 20, vec2::new(0.0, 9.0), 30), ivec2::new(20, 30));
    assert_eq(associated_min4(x, 1, y, 2, vec2::splat(3.0), 3, vec2::splat(0.0), 4), ivec2::new(4, 4));
    assert_eq(associated_max4(x, 1, y, 2, vec2::splat(3.0), 3, vec2::splat(0.0), 4), ivec2::new(3, 1));
    // The 2- and 3-pair max pass the value through the key type: 300 is 44 as an i8.
    assert_eq(associated_max(i8vec2::new(1, 2), 300, i8vec2::new(0, 3), 7), ivec2::new(44, 7));
    assert_eq(associated_max(x, 16777217, y, 0), ivec2::new(0, 16777216));
}

@test
fn integer_pow_edges() {
    assert_eq(pow_int(0, 0), 1);
    assert_eq(pow_int(-1, 1001), -1);
    assert_eq(pow_int(-1, 1000), 1);
    assert_eq(pow_int(-2, 31), i32::MIN);
    assert_eq(pow_int(2u32, 32), 0u32);
    assert_eq(pow_int(3u32, 21), 1870418611u32);
    assert_eq(P4, 81u32);
}

@test(should_panic)
fn integer_pow_overflow_traps() {
    let x = pow_int(2, 31);
    assert(x != 0);
}

@test
fn integer_sqrt_edges() {
    assert_eq(sqrt_int(-5), -5);
    assert_eq(sqrt_int(0), 0);
    assert_eq(sqrt_int(1), 1);
    assert_eq(sqrt_int(2), 1);
    assert_eq(sqrt_int(99), 9);
    assert_eq(sqrt_int(i32::MAX), 46340);
    assert_eq(sqrt_int(u32::MAX), 65535u32);
    assert_eq(sqrt_int(4294836225u32), 65535u32);
    assert_eq(S10, 10);
    for x in 0u32..20000 {
        let r = sqrt_int(x);
        assert(r * r <= x);
        assert((r + 1) * (r + 1) > x);
    }
}

@test
fn integer_mod_edges() {
    assert_eq(mod_int(7, 3), 1);
    assert_eq(mod_int(-7, 3), 2);
    assert_eq(mod_int(7, -3), -2);
    assert_eq(mod_int(-7, -3), -1);
    assert_eq(mod_int(7u32, 3), 1u32);
    assert_eq(mod_int(u32::MAX, 10), 5u32);
}

@test(should_panic)
fn integer_mod_by_zero_traps() {
    let x = mod_int(7u32, 0);
    assert(x != 1);
}

@test
fn integer_nlz_edges() {
    assert_eq(nlz(0), 32u32);
    assert_eq(nlz(1), 31u32);
    assert_eq(nlz(u32::MAX), 0u32);
}

@test
fn integer_factorial() {
    assert_eq(factorial(0), 1);
    assert_eq(factorial(-3), 1);
    assert_eq(factorial(1), 1);
    assert_eq(factorial(12), 479001600);
    assert_eq(F5, 120);
    assert_eq(factorial(20i64), 2432902008176640000i64);
    assert_eq(factorial(6u8), 208u8);
    assert_eq(factorial(127i8), 0i8);
    assert_eq(factorial(u64::MAX), 0u64);
    assert_eq(factorial(4.5f64), 59.0625);
    assert_eq(factorial(ivec3::new(3, 4, 5)), ivec3::new(6, 24, 120));
    // An infinite or huge float gives infinity: the loop stops after 256 factors.
    assert(factorial(f32::infinity()).is_inf());
    assert(factorial(1e30f32).is_inf());
    assert(factorial(f64::nan()) == 1.0);
}

@test(should_panic)
fn integer_factorial_overflow_traps() {
    let x = factorial(13);
    assert(x != 0);
}

@test
fn optimum_pow() {
    assert_eq(pow2(3), 9);
    assert_eq(pow3(-3), -27);
    assert_eq(pow4(3), 81);
    assert_eq(pow2(vec2::new(2.0, -3.0)), vec2::new(4.0, 9.0));
    assert_eq(pow3(dvec3::splat(2.0)), dvec3::splat(8.0));
    assert_eq(pow4(uvec4::splat(256)), uvec4::splat(0));
    assert_eq(pow2(200u8), 64u8);
    assert_eq(pow4(1.1f32), 1.1f32 * 1.1 * (1.1f32 * 1.1));
}

@test
fn handed_coordinate_space() {
    let t = vec3::new(1.0, 0.0, 0.0);
    let b = vec3::new(0.0, 1.0, 0.0);
    let n = vec3::new(0.0, 0.0, 1.0);
    assert(right_handed(t, b, n));
    assert(!left_handed(t, b, n));
    assert(left_handed(t, -b, n));
    assert(!right_handed(dvec3::zero(), dvec3::zero(), dvec3::zero()));
    assert(!left_handed(dvec3::zero(), dvec3::zero(), dvec3::zero()));
}

@test
fn pca_edges() {
    let none: []Vec<f32, 3> = [];
    assert_eq(compute_covariance_matrix(none), mat3::zero());
    assert_eq(compute_covariance_matrix_with_center(none, vec3::splat(1.0)), mat3::zero());
    let ints = [ivec2::new(2, 4), ivec2::new(-2, 0)];
    assert_eq(compute_covariance_matrix(ints[0..2]), imat2::new(4, 4, 4, 8));
    assert_eq(compute_covariance_matrix_with_center(ints[0..2], ivec2::new(0, 2)), imat2::new(4, 4, 4, 4));
    // An eigenvalue that needs more than 30 QL iterations: count 0 and zero outputs.
    let (count, ev, evec) = find_eigenvalues_sym_real(mat2::diagonal(f32::nan()));
    assert_eq(count, 0u32);
    assert_eq(ev, vec2::zero());
    assert_eq(evec, mat2::zero());
    let (n, values, vectors) = find_eigenvalues_sym_real(dmat3::new(2.0, 1.0, 0.0, 1.0, 2.0, 0.0, 0.0, 0.0, 3.0));
    assert_eq(n, 3u32);
    let (sv, sm) = sort_eigenvalues(values, vectors);
    assert(near_vec(sv, dvec3::new(3.0, 3.0, 1.0), 1e-12));
    for i in 0usize..3 {
        let m = dmat3::new(2.0, 1.0, 0.0, 1.0, 2.0, 0.0, 0.0, 0.0, 3.0);
        assert(near_vec(m * sm[i], sm[i] * sv[i], 1e-12));
    }
    let (n1, v1, m1) = find_eigenvalues_sym_real(dmat2::identity());
    assert_eq(n1, 2u32);
    assert_eq(v1, dvec2::splat(1.0));
    assert_eq(m1, dmat2::identity());
}

@test
fn flips() {
    let m = imat3x2::new(1, 2, 3, 4, 5, 6);
    assert_eq(fliplr(m), imat3x2::new(5, 6, 3, 4, 1, 2));
    assert_eq(flipud(m), imat3x2::new(2, 1, 4, 3, 6, 5));
    assert_eq(FLIP, imat2::new(3, 4, 1, 2));
}

// q * r reconstructs m with orthonormal q columns, and r * q for rq with orthonormal q rows.
fn factor_check<const C: usize, const R: usize, const K: usize>(
    m: Mat<f64, C, R>,
    left: Mat<f64, K, R>,
    right: Mat<f64, C, K>,
) bool {
    return near_mat(left * right, m, 1e-9);
}

@test
fn qr_rq_every_shape() {
    let mut rng = Pcg32::new(7, 54);
    let m22 = linear_rand_mat::<2, 2>(&mut rng);
    let m23 = linear_rand_mat::<2, 3>(&mut rng);
    let m24 = linear_rand_mat::<2, 4>(&mut rng);
    let m32 = linear_rand_mat::<3, 2>(&mut rng);
    let m33 = linear_rand_mat::<3, 3>(&mut rng);
    let m34 = linear_rand_mat::<3, 4>(&mut rng);
    let m42 = linear_rand_mat::<4, 2>(&mut rng);
    let m43 = linear_rand_mat::<4, 3>(&mut rng);
    let m44 = linear_rand_mat::<4, 4>(&mut rng);
    {
        let (q, r) = qr_decompose(m22);
        assert(factor_check(m22, q, r) && qr_errors(m22, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m23);
        assert(factor_check(m23, q, r) && qr_errors(m23, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m24);
        assert(factor_check(m24, q, r) && qr_errors(m24, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m32);
        assert(factor_check(m32, q, r) && qr_errors(m32, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m33);
        assert(factor_check(m33, q, r) && qr_errors(m33, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m34);
        assert(factor_check(m34, q, r) && qr_errors(m34, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m42);
        assert(factor_check(m42, q, r) && qr_errors(m42, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m43);
        assert(factor_check(m43, q, r) && qr_errors(m43, q, r) == 0);
    }
    {
        let (q, r) = qr_decompose(m44);
        assert(factor_check(m44, q, r) && qr_errors(m44, q, r) == 0);
    }
    {
        let (r, q) = rq_decompose(m22);
        assert(factor_check(m22, r, q));
    }
    {
        let (r, q) = rq_decompose(m23);
        assert(factor_check(m23, r, q));
    }
    {
        let (r, q) = rq_decompose(m24);
        assert(factor_check(m24, r, q));
    }
    {
        let (r, q) = rq_decompose(m32);
        assert(factor_check(m32, r, q));
    }
    {
        let (r, q) = rq_decompose(m33);
        assert(factor_check(m33, r, q));
    }
    {
        let (r, q) = rq_decompose(m34);
        assert(factor_check(m34, r, q));
    }
    {
        let (r, q) = rq_decompose(m42);
        assert(factor_check(m42, r, q));
    }
    {
        let (r, q) = rq_decompose(m43);
        assert(factor_check(m43, r, q));
    }
    {
        let (r, q) = rq_decompose(m44);
        assert(factor_check(m44, r, q));
    }
    let (fq, fr) = qr_decompose(mat3::new(1.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 3.0));
    assert_eq(fq, mat3::identity());
    assert_eq(fr, mat3::new(1.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 3.0));
}

fn linear_rand_mat<const C: usize, const R: usize>(rng: &mut Pcg32) Mat<f64, C, R> {
    let mut m = Mat::<f64, C, R>::zero();
    for i in 0..C {
        m[i] = linear_rand(rng, Vec::<f64, R>::splat(-10.0), Vec::<f64, R>::splat(10.0));
    }
    return m;
}

@test
fn cross_product_matrices() {
    let x = dvec3::new(1.5, -2.0, 0.25);
    let y = dvec3::new(-3.0, 0.5, 4.0);
    assert(near_vec(matrix_cross3(x) * y, cross(x, y), 1e-12));
    let m4 = matrix_cross4(x);
    assert_eq(m4[3], dvec4::zero());
    assert_eq(m4[0][3], 0.0);
    assert_eq(dmat3::from_mat(m4), matrix_cross3(x));
    assert_eq(CROSS3, imat3::new(0, 3, -2, -3, 0, 1, 2, -1, 0));
    assert_eq(matrix_cross3(uvec3::new(1, 0, 0))[2][1], u32::MAX);
    assert(
        near(
            mixed_product(x, y, dvec3::new(1.0, 2.0, 3.0)),
            determinant(dmat3::cols(x, y, dvec3::new(1.0, 2.0, 3.0))),
            1e-12,
        ),
    );
}

@test
fn major_storage() {
    let a = vec3::new(1.0, 2.0, 3.0);
    let b = vec3::new(4.0, 5.0, 6.0);
    let c = vec3::new(7.0, 8.0, 9.0);
    assert_eq(row_major3(a, b, c), transpose(col_major3(a, b, c)));
    assert_eq(col_major3(a, b, c), mat3::cols(a, b, c));
    assert_eq(row_major3_from_mat(mat3::cols(a, b, c)), row_major3(a, b, c));
    assert_eq(col_major3_from_mat(mat3::cols(a, b, c)), mat3::cols(a, b, c));
    assert_eq(ROWS2, mat2::new(1.0, 3.0, 2.0, 4.0));
    assert_eq(col_major2(ivec2::new(1, 2), ivec2::new(3, 4)), imat2::new(1, 2, 3, 4));
    assert_eq(row_major2_from_mat(imat2::new(1, 2, 3, 4)), imat2::new(1, 3, 2, 4));
    assert_eq(col_major2_from_mat(imat2::new(1, 2, 3, 4)), imat2::new(1, 2, 3, 4));
    let v = [dvec4::splat(1.0), dvec4::splat(2.0), dvec4::splat(3.0), dvec4::splat(4.0)];
    assert_eq(row_major4(v[0], v[1], v[2], v[3]), transpose(col_major4(v[0], v[1], v[2], v[3])));
    assert_eq(row_major4_from_mat(col_major4(v[0], v[1], v[2], v[3])), row_major4(v[0], v[1], v[2], v[3]));
    assert_eq(col_major4_from_mat(dmat4::identity()), dmat4::identity());
}

@test
fn texture_levels_forms() {
    assert_eq(LEVELS, 2);
    assert_eq(levels(256u32), 9u32);
    assert_eq(levels(0u32), 0u32);
    assert_eq(levels(uvec3::new(4, 64, 8)), 7u32);
    assert_eq(levels(4.0f32), 3.0);
    assert(near(levels(dvec2::new(3.0, 2.0)), 3.0f64.log2() + 1.0, 1e-15));
}

@test
fn common_edges() {
    assert(isdenormal(1e-40f32));
    assert(!isdenormal(f32::min_positive()));
    assert(!isdenormal(0.0f32));
    assert(isdenormal(dvec2::new(5e-324, 1.0)) == bvec2::new(true, false));
    assert(!isdenormal(f64::nan()));
    assert_eq(fmod(-7, 3), -1);
    assert_eq(fmod(7u8, 3), 1u8);
    assert(fmod(1.0f32, 0.0).is_nan());
    assert_eq(open_bounded(vec2::new(f32::nan(), 0.5), vec2::zero(), vec2::splat(1.0)), bvec2::new(false, true));
    assert_eq(close_bounded(vec2::new(0.0, 1.5), vec2::zero(), vec2::splat(1.0)), bvec2::new(true, false));
}

@test(should_panic)
fn common_fmod_by_zero_traps() {
    let x = fmod(ivec2::splat(1), 0);
    assert(x[0] != 1);
}

@test
fn extend_forms() {
    assert_eq(extend_by(1.0, 3.0, 2.0), 5.0);
    assert_eq(extend_by(vec2::splat(1.0), vec2::new(2.0, 3.0), 2.0), vec2::new(3.0, 5.0));
    assert_eq(extend_by(ivec3::splat(1), ivec3::new(2, 3, 4), ivec3::new(1, 2, 3)), ivec3::new(2, 5, 10));
    assert_eq(extend_by(200u8, 100, 3), 156u8);
}

@test
fn normalize_dot_forms() {
    let x = vec4::new(1.0, -2.0, 3.0, 0.5);
    let y = vec4::new(0.5, 4.0, -1.0, 2.0);
    let exact = normalize_dot(x, y);
    assert(near(exact, dot(normalize(x), normalize(y)), 0.000001));
    let fast = fast_normalize_dot(x, y);
    assert(near(fast, exact, 0.002));
    // f32: one Newton step from the bit estimate 0x5f375a86 - (bits >> 1).
    let s = dot(x, x) * dot(y, y);
    let t = f32_from_bits(0x5f375a86u32 - (f32_bits(s) >> 1));
    assert_eq(fast, dot(x, y) * (t * (1.5 - s * 0.5 * t * t)));
    // f64: 1 / sqrt.
    let dx = dvec2::new(3.0, 4.0);
    let dy = dvec2::new(-4.0, 3.0);
    assert_eq(fast_normalize_dot(dx, dy), normalize_dot(dx, dy));
    assert_eq(normalize_dot(dvec1::splat(-2.0), dvec1::splat(3.0)), -1.0);
}

@test
fn rotate_normalized_axis_forms() {
    let axis = dvec3::new(0.0, 0.6, 0.8);
    let q = rotate_normalized_axis(dquat::identity(), 1.25f64, axis);
    let expect = angle_axis(1.25f64, axis);
    assert(
        near(q.w, expect.w, 1e-15) && near(q.x, expect.x, 1e-15) && near(q.y, expect.y, 1e-15) && near(
            q.z,
            expect.z,
            1e-15,
        ),
    );
    let m = rotate_normalized_axis(dmat4::identity(), 1.25f64, axis);
    assert(near_mat(m, mat4_cast(expect), 1e-14));
    assert(near_mat(m, rotate(dmat4::identity(), 1.25f64, axis), 1e-14));
}
