#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

// Crop selection is a preview-only step. This function never sends a message;
// Telegram's existing Send button remains responsible for sending.
#ifdef __cplusplus
extern "C" {
#endif
void MxPresentVideoNoteCrop(UIView *sourceView, id galleryItem,
                            CGPoint initialCenter, CGFloat initialZoom,
                            BOOL alreadySelected,
                            void (^onApply)(CGPoint center, CGFloat zoom),
                            dispatch_block_t onSendNormally);
#ifdef __cplusplus
}
#endif
