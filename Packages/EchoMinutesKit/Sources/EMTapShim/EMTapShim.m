#import "EMTapShim.h"

CATapDescription *EMMakeMixdownTap(NSArray<NSNumber *> *processObjectIDs) {
    return [[CATapDescription alloc] initStereoMixdownOfProcesses:processObjectIDs];
}

CATapDescription *EMMakeGlobalTapExcluding(NSArray<NSNumber *> *processObjectIDs) {
    return [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:processObjectIDs];
}
