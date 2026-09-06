# Build matrix report

build 0f61514303ca, 14 cores, 5 reps per case, 1-minute load 5.1 to 12.2 during the run (a game was running), dev profile unless noted; global object cache and ccache off throughout.

| case | workers | runs | transpile ms med / p95 | compile ms med / p95 | link ms med / p95 | total ms med / p95 | units stale | cc span ms | cc overlap ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| body | 1 | 5 | 747.6 / 748.7 | 744.3 / 756.6 | 77.4 / 78.7 | 1602.0 / 1616.3 | 1/91 | 783.5 | 5.4 |
| body | 14 | 5 | 334.9 / 357.5 | 748.9 / 758.8 | 78.3 / 79.2 | 1192.1 / 1206.1 | 1/91 | 780.4 | 6.2 |
| clean | 1 | 5 | 748.5 / 778.0 | 58895.5 / 59166.1 | 78.2 / 87.2 | 59753.5 / 60060.3 | 91/91 | 59295.0 | 374.2 |
| clean | 14 | 5 | 398.9 / 405.0 | 6717.4 / 8147.9 | 82.0 / 83.4 | 7224.5 / 8652.9 | 91/91 | 6954.9 | 204.4 |
| layout | 1 | 5 | 730.0 / 734.9 | 58778.5 / 59098.1 | 78.7 / 80.3 | 59614.4 / 59946.2 | 87/91 | 58835.8 | 28.4 |
| layout | 14 | 5 | 382.7 / 407.2 | 6437.8 / 6640.6 | 79.3 / 84.9 | 6914.8 / 7133.6 | 69/91 | 6526.9 | 76.3 |
| release_relink | 1 | 5 | 751.3 / 816.3 | 190.6 / 198.0 | 20520.0 / 20634.7 | 21495.2 / 21672.2 | 1/91 | 225.9 | 6.1 |
| release_relink | 14 | 5 | 336.2 / 339.7 | 197.4 / 199.5 | 20447.3 / 20482.6 | 20997.9 / 21034.7 | 1/91 | 225.9 | 5.5 |
| signature | 1 | 5 | 740.4 / 749.7 | 58788.8 / 58875.2 | 79.3 / 80.6 | 59642.6 / 59736.2 | 88/91 | 58848.4 | 26.8 |
| signature | 14 | 5 | 395.0 / 405.0 | 6506.0 / 6655.0 | 78.9 / 79.3 | 7017.6 / 7153.8 | 87/91 | 6601.8 | 69.6 |
| tucache_off | 14 | 5 | 327.5 / 360.2 | 755.4 / 762.4 | 77.8 / 79.5 | 1187.9 / 1216.3 | 1/91 | 781.8 | 3.9 |
| tucache_on | 14 | 5 | 332.4 / 336.6 | 752.5 / 763.2 | 77.9 / 78.6 | 1189.2 / 1193.4 | 1/91 | 781.0 | 5.6 |
| unchanged | 1 | 5 | 2.9 / 3.3 | 14.6 / 14.8 | 0.2 / 0.2 | 17.6 / 18.0 | 0/91 | 0.0 | 0.0 |
| unchanged | 14 | 5 | 2.9 / 3.0 | 14.3 / 19.2 | 0.2 / 0.2 | 17.5 / 22.3 | 0/91 | 0.0 | 0.0 |

## Memory (one tracked run each, every core)

| case | boundary | peak RSS MiB | alloc calls | requested MiB | live MiB | survivors from earlier phases |
|---|---|---:|---:|---:|---:|---|
| body_j14 | frontend | 87.7 | 43627 | 130.5 | 94.0 | - |
| body_j14 | borrowck | 167.4 | 319006 | 335.6 | 135.1 | frontend 2728/93.9 MiB |
| body_j14 | plan | 217.1 | 818556 | 557.7 | 142.3 | frontend 2684/93.9 MiB, borrowck 41326/41.2 MiB |
| body_j14 | publish | 310.8 | 1354965 | 1010.6 | 117.5 | frontend 2684/93.9 MiB, borrowck 6025/5.6 MiB, plan 100/0.3 MiB |
| body_j14 | build | 310.8 | 1358947 | 1046.5 | 0.0 | frontend 1/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
| clean_j14 | frontend | 87.3 | 43560 | 130.5 | 94.0 | - |
| clean_j14 | borrowck | 167.6 | 318987 | 335.6 | 135.1 | frontend 2728/93.9 MiB |
| clean_j14 | plan | 216.7 | 818574 | 557.6 | 142.3 | frontend 2684/93.9 MiB, borrowck 41326/41.2 MiB |
| clean_j14 | publish | 302.9 | 1354679 | 976.1 | 117.6 | frontend 2684/93.9 MiB, borrowck 6025/5.6 MiB, plan 100/0.3 MiB |
| clean_j14 | build | 302.9 | 1360575 | 1012.2 | 0.0 | frontend 1/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
| unchanged_j14 | frontend | 2.2 | 560 | 0.1 | 0.0 | - |
| unchanged_j14 | borrowck | 2.2 | 560 | 0.1 | 0.0 | frontend 12/0.0 MiB |
| unchanged_j14 | plan | 2.2 | 560 | 0.1 | 0.0 | frontend 12/0.0 MiB, borrowck 0/0.0 MiB |
| unchanged_j14 | publish | 2.2 | 560 | 0.1 | 0.0 | frontend 12/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB |
| unchanged_j14 | build | 2.7 | 5858 | 0.9 | 0.0 | frontend 1/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
