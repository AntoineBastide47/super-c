#ifndef SUPER___STD__RANGE_H
#define SUPER___STD__RANGE_H

#include "../super_rt.h"

typedef struct Range__usize Range__usize;

struct Range__usize {
  size_t start;
  size_t end;
  bool inclusive;
};



#endif
