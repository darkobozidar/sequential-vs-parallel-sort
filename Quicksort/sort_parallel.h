#ifndef SORT_PARALLEL_H
#define SORT_PARALLEL_H


double sortParallel(
    data_t *h_output, data_t *d_dataTable, data_t *h_minMaxValues, h_glob_seq_t *h_globalSeqHost,
    h_glob_seq_t *h_globalSeqHostBuffer, d_glob_seq_t *h_globalSeqDev, d_glob_seq_t *d_globalSeqDev,
    uint_t *h_globalSeqIndexes, uint_t *d_globalSeqIndexes, loc_seq_t *h_localSeq, loc_seq_t *d_localSeq,
    uint_t tableLen, order_t sortOrder
);

#endif
