#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#if __has_include(<CoreAudio/CATapDescription.h>)
#import <CoreAudio/CATapDescription.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Stereo mixdown tap of the given Core Audio *process objects* (not PIDs).
CATapDescription *SLMakeMixdownTap(NSArray<NSNumber *> *processObjectIDs) API_AVAILABLE(macos(14.2));

/// Stereo global tap of every process except the given process objects.
CATapDescription *SLMakeGlobalTapExcluding(NSArray<NSNumber *> *processObjectIDs) API_AVAILABLE(macos(14.2));

NS_ASSUME_NONNULL_END
