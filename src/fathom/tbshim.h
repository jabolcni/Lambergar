#ifndef TBSHIM_H
#define TBSHIM_H

#include <stdint.h>

unsigned tb_probe_wdl_shim(
    uint64_t white,
    uint64_t black,
    uint64_t kings,
    uint64_t queens,
    uint64_t rooks,
    uint64_t bishops,
    uint64_t knights,
    uint64_t pawns,
    unsigned ep,
    unsigned turn);

unsigned tb_probe_root_shim(
    uint64_t white,
    uint64_t black,
    uint64_t kings,
    uint64_t queens,
    uint64_t rooks,
    uint64_t bishops,
    uint64_t knights,
    uint64_t pawns,
    unsigned rule50,
    unsigned ep,
    unsigned turn,
    unsigned *results);

#endif
