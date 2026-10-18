// std::math in one import: `import std::math::all as *;` names every type, alias and function of
// std::math unqualified. A module can also be imported alone (`import std::math::vec as v;`). The less
// common helpers of `std::math::extra` are not included: `import std::math::extra as *;` adds them, with
// no name in common with this module.
// Parts of this module derive from third-party code under the MIT license; see std/math/LICENSE.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::dual_quat as *;
import std::math::geometric as *;
import std::math::fused as *;
import std::math::intersect as *;
import std::math::query as *;
import std::math::compare as *;
import std::math::common as *;
import std::math::spline as *;
import std::math::easing as *;
import std::math::elementary as *;
import std::math::integer as *;
import std::math::packing as *;
import std::math::transform as *;
import std::math::euler as *;
import std::math::color as *;
import std::math::format as *;
import std::math::noise as *;
import std::math::random as *;
import std::math::projection as *;
