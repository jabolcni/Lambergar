#include "affine.h"

#if defined(__AVX2__)
#include <immintrin.h>

// Helper to clamp and pack i32 to u8
static uint8_t clamp_and_pack(int32_t val) {
    val >>= 6;
    if (val < 0) return 0;
    if (val > 127) return 127;
    return (uint8_t)val;
}

void affine_c(
    const uint8_t* input,
    uint8_t* output,
    const int32_t* biases,
    const int8_t* weights,
    int input_len,
    int output_len
) {
    for (int out_idx = 0; out_idx < output_len; ++out_idx) {
        int32_t sum = biases[out_idx];
        int i = 0;
        const int8_t* w_row = weights + (size_t)out_idx * input_len;

        // AVX2 part for 32 bytes at a time
        __m256i total_sum_vec = _mm256_setzero_si256();

        for (; i + 31 < input_len; i += 32) {
            // Load 32 u8 inputs and 32 i8 weights
            __m256i x_vec_u8 = _mm256_loadu_si256((const __m256i*)(input + i));
            __m256i w_vec_i8 = _mm256_loadu_si256((const __m256i*)(w_row + i));

            // VPMADDUBSW: Multiply u8 with i8 and horizontally add pairs of 16-bit results
            __m256i prod_i16 = _mm256_maddubs_epi16(x_vec_u8, w_vec_i8);

            // VPMADDWD: Multiply i16 with i16 (here, with a vector of 1s) and horizontally add pairs
            __m256i ones_i16 = _mm256_set1_epi16(1);
            __m256i sum_i32 = _mm256_madd_epi16(prod_i16, ones_i16);

            // Accumulate the sums
            total_sum_vec = _mm256_add_epi32(total_sum_vec, sum_i32);
        }

        // Horizontal sum of the final accumulator vector
        __m128i lo_128 = _mm256_castsi256_si128(total_sum_vec);
        __m128i hi_128 = _mm256_extracti128_si256(total_sum_vec, 1);
        __m128i sum_128 = _mm_add_epi32(lo_128, hi_128);
        sum_128 = _mm_hadd_epi32(sum_128, sum_128);
        sum_128 = _mm_hadd_epi32(sum_128, sum_128);
        sum += _mm_cvtsi128_si32(sum_128);

        // Scalar part for the remainder
        for (; i < input_len; ++i) {
            sum += (int32_t)input[i] * (int32_t)w_row[i];
        }

        output[out_idx] = clamp_and_pack(sum);
    }
}

#else

// Fallback scalar implementation if AVX2 is not available
void affine_c(
    const uint8_t* input,
    uint8_t* output,
    const int32_t* biases,
    const int8_t* weights,
    int input_len,
    int output_len
) {
    for (int out_idx = 0; out_idx < output_len; ++out_idx) {
        int32_t sum = biases[out_idx];
        const int8_t* w_row = weights + (size_t)out_idx * input_len;
        for (int i = 0; i < input_len; ++i) {
            sum += (int32_t)input[i] * (int32_t)w_row[i];
        }

        sum >>= 6;
        if (sum < 0) sum = 0;
        if (sum > 127) sum = 127;
        output[out_idx] = (uint8_t)sum;
    }
}

#endif // __AVX2__
