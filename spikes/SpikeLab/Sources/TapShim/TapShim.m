#import "TapShim.h"

CATapDescription *SLMakeMixdownTap(NSArray<NSNumber *> *processObjectIDs) {
    return [[CATapDescription alloc] initStereoMixdownOfProcesses:processObjectIDs];
}

CATapDescription *SLMakeGlobalTapExcluding(NSArray<NSNumber *> *processObjectIDs) {
    return [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:processObjectIDs];
}
