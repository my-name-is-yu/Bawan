#import <Foundation/Foundation.h>

#include "TranslationEngine.h"

@protocol MemoryProbeHost <NSObject>
- (void)memoryProbeShowTranslationPanel;
- (void)openSettings:(id)sender;
- (void)showOnboarding;
- (void)memoryProbeClosePanel;
- (void)prepareModel;
- (BOOL)hasVerifiedModelFile;
- (BOOL)modelFailed;
- (void)translateText:(NSString *)text direction:(bawan::Direction)direction;
@end

@interface MemoryProbe : NSObject
+ (instancetype)probeWithEnvironment:(NSDictionary *)environment host:(id<MemoryProbeHost>)host;
- (void)start;
- (void)tick;
- (void)recordEngineEvent:(bawan::EngineEvent::Kind)kind;
@end
