//
//  AudioMixer-Bridging-Header.h
//  AudioMixer
//
//  Единственное, что приходит из C, — атомарные операции над Float для
//  realtime-потока. Objective-C в проекте нет.
//

#import "Utilities/AudioMixerAtomics.h"
