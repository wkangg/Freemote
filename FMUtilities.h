#import <Foundation/Foundation.h>

// Small helpers shared by more than one file

// Missing, or JSON null
static inline BOOL FMIsNull(id value) {
    return !value || value == [NSNull null];
}
