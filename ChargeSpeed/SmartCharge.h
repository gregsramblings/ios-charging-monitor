#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Snapshot of the charging-intelligence settings reported by the private
/// PowerUI framework (`PowerUISmartChargeClient`). Integer fields use -1 for "unknown".
@interface SmartChargeStatus : NSObject
@property (nonatomic) BOOL available;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic) BOOL obcSupported;                 // Optimized Battery Charging
@property (nonatomic) BOOL mclSupported;                 // Manual Charge Limit (the 80 % setting)
@property (nonatomic) BOOL deocSupported;                // DEoC, believed to be Clean Energy Charging
@property (nonatomic) NSInteger obcEnabled;
@property (nonatomic) NSInteger mclEnabled;
@property (nonatomic) NSInteger deocEnabled;
@property (nonatomic) NSInteger mclLimit;                // percent
@property (nonatomic) NSInteger currentChargeLimit;      // percent
@property (nonatomic) NSInteger recommendedChargeLimit;  // percent
@property (nonatomic) NSInteger obcEngaged;              // 1 = holding charge right now
@property (nonatomic) NSInteger engagedChargeLimit;      // percent
@property (nonatomic) NSInteger chargingOverrideAllowed;
@property (nonatomic) NSInteger uiState;
@property (nonatomic, strong, nullable) NSDate *fullChargeDeadline;
@property (nonatomic, copy, nullable) NSDictionary *rawStatus;
@property (nonatomic, copy) NSArray<NSString *> *callErrors;
@end

/// Talks to PowerUISmartChargeClient through the ObjC runtime so no private headers are needed.
@interface SmartChargeReader : NSObject
- (nullable instancetype)init;
- (SmartChargeStatus *)read;
@end

/// 64-bit state attached to the `com.apple.powerui.smartchargestatuschanged` Darwin notification.
/// Returns -1 if the notification cannot be registered.
int64_t SmartChargeNotificationState(void);

NS_ASSUME_NONNULL_END
