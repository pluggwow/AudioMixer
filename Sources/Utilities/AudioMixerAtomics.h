//
//  AudioMixerAtomics.h
//  AudioMixer
//
//  Атомарное чтение и запись Float для обмена между UI-потоком и
//  realtime-потоком Core Audio.
//
//  Зачем вообще: гейны пишет очередь движка, а читает аудиопоток, и делают они
//  это без общего лока — он там запрещён. Обычное присваивание Float в такой
//  паре потоков это гонка, то есть неопределённое поведение: на практике
//  выровненная 32-битная запись атомарна и всё работает, но по правилам языка
//  компилятор вправе, например, векторизовать цикл записи, и гарантия
//  рассыплется. Здесь она становится настоящей.
//
//  Порядок relaxed: нам нужна только целостность отдельного значения, никакой
//  синхронизации с другими записями. На arm64 и x86_64 это ровно те же
//  инструкции, что и обычное присваивание, — плата нулевая.
//
//  Float хранится образом в uint32_t: __atomic-встроенные работают с целыми,
//  а Swift не умеет импортировать типы с _Atomic. Через обычный указатель
//  и встроенные функции — умеет.
//

#ifndef AUDIOMIXER_ATOMICS_H
#define AUDIOMIXER_ATOMICS_H

#include <stdint.h>
#include <string.h>

static inline void AudioMixerStoreFloatRelaxed(uint32_t *slot, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    __atomic_store_n(slot, bits, __ATOMIC_RELAXED);
}

static inline float AudioMixerLoadFloatRelaxed(const uint32_t *slot) {
    uint32_t bits = __atomic_load_n(slot, __ATOMIC_RELAXED);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

#endif /* AUDIOMIXER_ATOMICS_H */
