#include "affine.h"
#include <stdint.h>

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
    int out_idx = 0;
    const __m256i ones_i16 = _mm256_set1_epi16(1);

    // Process two output elements at a time
    for (; out_idx + 1 < output_len; out_idx += 2) {
        int32_t sum0 = biases[out_idx];
        int32_t sum1 = biases[out_idx + 1];
        const int8_t* w_row0 = weights + (size_t)out_idx * input_len;
        const int8_t* w_row1 = weights + (size_t)(out_idx + 1) * input_len;

        __m256i total_sum0_vec0 = _mm256_setzero_si256();
        __m256i total_sum0_vec1 = _mm256_setzero_si256();
        __m256i total_sum0_vec2 = _mm256_setzero_si256();
        __m256i total_sum0_vec3 = _mm256_setzero_si256();
        
        __m256i total_sum1_vec0 = _mm256_setzero_si256();
        __m256i total_sum1_vec1 = _mm256_setzero_si256();
        __m256i total_sum1_vec2 = _mm256_setzero_si256();
        __m256i total_sum1_vec3 = _mm256_setzero_si256();

        int i = 0;
        for (; i + 127 < input_len; i += 128) {
            // Chunk 0
            __m256i x0 = _mm256_loadu_si256((const __m256i*)(input + i + 0));
            __m256i w00 = _mm256_loadu_si256((const __m256i*)(w_row0 + i + 0));
            __m256i w10 = _mm256_loadu_si256((const __m256i*)(w_row1 + i + 0));
            __m256i p00 = _mm256_maddubs_epi16(x0, w00);
            __m256i p10 = _mm256_maddubs_epi16(x0, w10);
            __m256i s00 = _mm256_madd_epi16(p00, ones_i16);
            __m256i s10 = _mm256_madd_epi16(p10, ones_i16);
            total_sum0_vec0 = _mm256_add_epi32(total_sum0_vec0, s00);
            total_sum1_vec0 = _mm256_add_epi32(total_sum1_vec0, s10);

            // Chunk 1
            __m256i x1 = _mm256_loadu_si256((const __m256i*)(input + i + 32));
            __m256i w01 = _mm256_loadu_si256((const __m256i*)(w_row0 + i + 32));
            __m256i w11 = _mm256_loadu_si256((const __m256i*)(w_row1 + i + 32));
            __m256i p01 = _mm256_maddubs_epi16(x1, w01);
            __m256i p11 = _mm256_maddubs_epi16(x1, w11);
            __m256i s01 = _mm256_madd_epi16(p01, ones_i16);
            __m256i s11 = _mm256_madd_epi16(p11, ones_i16);
            total_sum0_vec1 = _mm256_add_epi32(total_sum0_vec1, s01);
            total_sum1_vec1 = _mm256_add_epi32(total_sum1_vec1, s11);

            // Chunk 2
            __m256i x2 = _mm256_loadu_si256((const __m256i*)(input + i + 64));
            __m256i w02 = _mm256_loadu_si256((const __m256i*)(w_row0 + i + 64));
            __m256i w12 = _mm256_loadu_si256((const __m256i*)(w_row1 + i + 64));
            __m256i p02 = _mm256_maddubs_epi16(x2, w02);
            __m256i p12 = _mm256_maddubs_epi16(x2, w12);
            __m256i s02 = _mm256_madd_epi16(p02, ones_i16);
            __m256i s12 = _mm256_madd_epi16(p12, ones_i16);
            total_sum0_vec2 = _mm256_add_epi32(total_sum0_vec2, s02);
            total_sum1_vec2 = _mm256_add_epi32(total_sum1_vec2, s12);

            // Chunk 3
            __m256i x3 = _mm256_loadu_si256((const __m256i*)(input + i + 96));
            __m256i w03 = _mm256_loadu_si256((const __m256i*)(w_row0 + i + 96));
            __m256i w13 = _mm256_loadu_si256((const __m256i*)(w_row1 + i + 96));
            __m256i p03 = _mm256_maddubs_epi16(x3, w03);
            __m256i p13 = _mm256_maddubs_epi16(x3, w13);
            __m256i s03 = _mm256_madd_epi16(p03, ones_i16);
            __m256i s13 = _mm256_madd_epi16(p13, ones_i16);
            total_sum0_vec3 = _mm256_add_epi32(total_sum0_vec3, s03);
            total_sum1_vec3 = _mm256_add_epi32(total_sum1_vec3, s13);
        }

        total_sum0_vec0 = _mm256_add_epi32(total_sum0_vec0, total_sum0_vec1);
        total_sum0_vec2 = _mm256_add_epi32(total_sum0_vec2, total_sum0_vec3);
        total_sum0_vec0 = _mm256_add_epi32(total_sum0_vec0, total_sum0_vec2);

        total_sum1_vec0 = _mm256_add_epi32(total_sum1_vec0, total_sum1_vec1);
        total_sum1_vec2 = _mm256_add_epi32(total_sum1_vec2, total_sum1_vec3);
        total_sum1_vec0 = _mm256_add_epi32(total_sum1_vec0, total_sum1_vec2);

        for (; i + 31 < input_len; i += 32) {
            __m256i x = _mm256_loadu_si256((const __m256i*)(input + i));
            
            __m256i w0 = _mm256_loadu_si256((const __m256i*)(w_row0 + i));
            __m256i p0 = _mm256_maddubs_epi16(x, w0);
            __m256i s0 = _mm256_madd_epi16(p0, ones_i16);
            total_sum0_vec0 = _mm256_add_epi32(total_sum0_vec0, s0);

            __m256i w1 = _mm256_loadu_si256((const __m256i*)(w_row1 + i));
            __m256i p1 = _mm256_maddubs_epi16(x, w1);
            __m256i s1 = _mm256_madd_epi16(p1, ones_i16);
            total_sum1_vec0 = _mm256_add_epi32(total_sum1_vec0, s1);
        }
        
        __m128i lo0 = _mm256_castsi256_si128(total_sum0_vec0);
        __m128i hi0 = _mm256_extracti128_si256(total_sum0_vec0, 1);
        __m128i sum0_128 = _mm_add_epi32(lo0, hi0);
        sum0_128 = _mm_hadd_epi32(sum0_128, sum0_128);
        sum0_128 = _mm_hadd_epi32(sum0_128, sum0_128);
        sum0 += _mm_cvtsi128_si32(sum0_128);

        __m128i lo1 = _mm256_castsi256_si128(total_sum1_vec0);
        __m128i hi1 = _mm256_extracti128_si256(total_sum1_vec0, 1);
        __m128i sum1_128 = _mm_add_epi32(lo1, hi1);
        sum1_128 = _mm_hadd_epi32(sum1_128, sum1_128);
        sum1_128 = _mm_hadd_epi32(sum1_128, sum1_128);
        sum1 += _mm_cvtsi128_si32(sum1_128);

        for (; i < input_len; ++i) {
            sum0 += (int32_t)input[i] * (int32_t)w_row0[i];
            sum1 += (int32_t)input[i] * (int32_t)w_row1[i];
        }

        output[out_idx] = clamp_and_pack(sum0);
        output[out_idx + 1] = clamp_and_pack(sum1);
    }

    // Remainder loop for odd output lengths
    for (; out_idx < output_len; ++out_idx) {
        int32_t sum = biases[out_idx];
        int i = 0;
        const int8_t* w_row = weights + (size_t)out_idx * input_len;

        __m256i total_sum_vec0 = _mm256_setzero_si256();
        __m256i total_sum_vec1 = _mm256_setzero_si256();
        __m256i total_sum_vec2 = _mm256_setzero_si256();
        __m256i total_sum_vec3 = _mm256_setzero_si256();

        for (; i + 127 < input_len; i += 128) {
            __m256i x0 = _mm256_loadu_si256((const __m256i*)(input + i + 0));
            __m256i w0 = _mm256_loadu_si256((const __m256i*)(w_row + i + 0));
            __m256i p0 = _mm256_maddubs_epi16(x0, w0);
            __m256i s0 = _mm256_madd_epi16(p0, ones_i16);
            total_sum_vec0 = _mm256_add_epi32(total_sum_vec0, s0);

            __m256i x1 = _mm256_loadu_si256((const __m256i*)(input + i + 32));
            __m256i w1 = _mm256_loadu_si256((const __m256i*)(w_row + i + 32));
            __m256i p1 = _mm256_maddubs_epi16(x1, w1);
            __m256i s1 = _mm256_madd_epi16(p1, ones_i16);
            total_sum_vec1 = _mm256_add_epi32(total_sum_vec1, s1);

            __m256i x2 = _mm256_loadu_si256((const __m256i*)(input + i + 64));
            __m256i w2 = _mm256_loadu_si256((const __m256i*)(w_row + i + 64));
            __m256i p2 = _mm256_maddubs_epi16(x2, w2);
            __m256i s2 = _mm256_madd_epi16(p2, ones_i16);
            total_sum_vec2 = _mm256_add_epi32(total_sum_vec2, s2);

            __m256i x3 = _mm256_loadu_si256((const __m256i*)(input + i + 96));
            __m256i w3 = _mm256_loadu_si256((const __m256i*)(w_row + i + 96));
            __m256i p3 = _mm256_maddubs_epi16(x3, w3);
            __m256i s3 = _mm256_madd_epi16(p3, ones_i16);
            total_sum_vec3 = _mm256_add_epi32(total_sum_vec3, s3);
        }

        total_sum_vec0 = _mm256_add_epi32(total_sum_vec0, total_sum_vec1);
        total_sum_vec2 = _mm256_add_epi32(total_sum_vec2, total_sum_vec3);
        total_sum_vec0 = _mm256_add_epi32(total_sum_vec0, total_sum_vec2);

        for (; i + 31 < input_len; i += 32) {
            __m256i x = _mm256_loadu_si256((const __m256i*)(input + i));
            __m256i w = _mm256_loadu_si256((const __m256i*)(w_row + i));
            __m256i p = _mm256_maddubs_epi16(x, w);
            __m256i s = _mm256_madd_epi16(p, ones_i16);
            total_sum_vec0 = _mm256_add_epi32(total_sum_vec0, s);
        }
        
        __m128i lo_128 = _mm256_castsi256_si128(total_sum_vec0);
        __m128i hi_128 = _mm256_extracti128_si256(total_sum_vec0, 1);
        __m128i sum_128 = _mm_add_epi32(lo_128, hi_128);
        sum_128 = _mm_hadd_epi32(sum_128, sum_128);
        sum_128 = _mm_hadd_epi32(sum_128, sum_128);
        sum += _mm_cvtsi128_si32(sum_128);

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
