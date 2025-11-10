#ifndef AFFINE_H
#define AFFINE_H

#include <stdint.h>

void affine_c(
    const uint8_t* input,
    uint8_t* output,
    const int32_t* biases,
    const int8_t* weights,
    int input_len,
    int output_len
);

#endif // AFFINE_H
