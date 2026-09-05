# Build matrix report

build c1682c74da42, 14 cores, 5 reps per case, dev profile unless noted; global object cache and ccache off throughout.

| case | workers | runs | transpile ms med / p95 | compile ms med / p95 | link ms med / p95 | total ms med / p95 | units stale | cc span ms | cc overlap ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| body | 1 | 5 | 667.4 / 672.0 | 667.8 / 687.6 | 69.7 / 70.7 | 1432.6 / 1451.3 | 1/91 | 698.1 | 4.8 |
| body | 14 | 5 | 310.6 / 325.9 | 670.4 / 675.6 | 68.9 / 70.0 | 1071.8 / 1081.6 | 1/91 | 696.4 | 4.7 |
| clean | 1 | 5 | 692.7 / 694.7 | 50455.4 / 51006.7 | 68.8 / 70.4 | 51242.5 / 51796.1 | 91/91 | 50810.4 | 336.0 |
| clean | 14 | 5 | 401.4 / 438.9 | 6468.2 / 8654.0 | 69.9 / 70.1 | 6966.8 / 9198.9 | 91/91 | 6716.2 | 221.4 |
| layout | 1 | 5 | 656.9 / 685.5 | 50430.7 / 50870.4 | 68.4 / 70.5 | 51180.6 / 51623.1 | 88/91 | 50480.6 | 25.5 |
| layout | 14 | 5 | 347.1 / 372.0 | 6603.4 / 7121.3 | 71.9 / 74.0 | 7070.4 / 7589.6 | 88/91 | 6705.9 | 64.4 |
| release_relink | 1 | 5 | 667.9 / 674.0 | 166.2 / 171.6 | 17794.0 / 17979.1 | 18654.2 / 18851.4 | 1/91 | 196.9 | 4.9 |
| release_relink | 14 | 5 | 312.9 / 326.4 | 169.2 / 173.2 | 17914.0 / 17996.8 | 18418.2 / 18503.0 | 1/91 | 194.6 | 4.7 |
| signature | 1 | 5 | 678.6 / 682.5 | 50635.2 / 50689.3 | 70.8 / 75.3 | 51419.9 / 51461.9 | 88/91 | 50686.7 | 24.5 |
| signature | 14 | 5 | 352.3 / 362.2 | 6438.2 / 6581.8 | 69.8 / 73.8 | 6889.5 / 7054.2 | 88/91 | 6527.3 | 63.8 |
| tucache_off | 14 | 5 | 299.0 / 323.5 | 677.0 / 691.6 | 71.0 / 72.6 | 1073.8 / 1091.7 | 1/91 | 702.2 | 3.6 |
| tucache_on | 14 | 5 | 305.6 / 350.8 | 672.5 / 674.5 | 69.8 / 71.7 | 1065.9 / 1118.2 | 1/91 | 698.0 | 4.7 |
| unchanged | 1 | 5 | 2.4 / 2.5 | 12.4 / 12.9 | 0.1 / 0.1 | 14.9 / 15.3 | 0/91 | 0.0 | 0.0 |
| unchanged | 14 | 5 | 2.5 / 2.5 | 11.9 / 12.2 | 0.1 / 0.1 | 14.4 / 14.8 | 0/91 | 0.0 | 0.0 |

## Memory (one tracked run each, every core)

| case | boundary | peak RSS MiB | alloc calls | requested MiB | live MiB | survivors from earlier phases |
|---|---|---:|---:|---:|---:|---|
| body_j14 | frontend | 86.5 | 43627 | 130.6 | 94.0 | - |
| body_j14 | borrowck | 166.4 | 319022 | 335.7 | 135.1 | frontend 2728/93.9 MiB |
| body_j14 | plan | 216.1 | 818572 | 557.7 | 142.3 | frontend 2684/93.9 MiB, borrowck 41326/41.2 MiB |
| body_j14 | publish | 308.7 | 1355468 | 1011.0 | 117.5 | frontend 2684/93.9 MiB, borrowck 6025/5.6 MiB, plan 100/0.3 MiB |
| body_j14 | build | 308.7 | 1359449 | 1046.9 | 0.0 | frontend 1/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
| clean_j14 | frontend | 87.0 | 43559 | 130.6 | 94.0 | - |
| clean_j14 | borrowck | 164.6 | 318954 | 335.7 | 135.1 | frontend 2728/93.9 MiB |
| clean_j14 | plan | 213.2 | 818541 | 557.7 | 142.3 | frontend 2684/93.9 MiB, borrowck 41326/41.2 MiB |
| clean_j14 | publish | 304.0 | 1352669 | 974.7 | 117.6 | frontend 2684/93.9 MiB, borrowck 6025/5.6 MiB, plan 100/0.3 MiB |
| clean_j14 | build | 304.0 | 1358564 | 1010.9 | 0.0 | frontend 1/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
| unchanged_j14 | frontend | 2.3 | 559 | 0.1 | 0.0 | - |
| unchanged_j14 | borrowck | 2.3 | 559 | 0.1 | 0.0 | frontend 12/0.0 MiB |
| unchanged_j14 | plan | 2.3 | 559 | 0.1 | 0.0 | frontend 12/0.0 MiB, borrowck 0/0.0 MiB |
| unchanged_j14 | publish | 2.3 | 559 | 0.1 | 0.0 | frontend 12/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB |
| unchanged_j14 | build | 2.8 | 5857 | 1.0 | 0.0 | frontend 1/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
