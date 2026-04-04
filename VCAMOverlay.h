// VCAMOverlay.h
#import <UIKit/UIKit.h>
#import <notify.h>

@interface VCAMOverlay : NSObject
+ (instancetype)shared;
+ (void)toggle;
+ (void)show;
+ (void)hide;
@end
