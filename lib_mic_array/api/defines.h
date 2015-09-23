#ifndef DEFINES_H_
#define DEFINES_H_

#define NUM_MICROPHONES         8
#define MAX_NUM_CHANNELS        8
#define PDM_BUFFER_LENGTH_LOG2  (10)
#define PDM_BUFFER_LENGTH  ((1<<PDM_BUFFER_LENGTH_LOG2)*MAX_NUM_CHANNELS) / sizeof(unsigned long long)

#endif /* DEFINES_H_ */
