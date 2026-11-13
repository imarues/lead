// Lead bindings for MX media UI, without changing the imported converters.
#pragma once
#import "UI/Headers.h"
#import "UI/LeadDesign.h"
#define MxLocalization LeadLocalization
#define MX_DIAG 0
#define mxDiag(fmt, ...) do { } while (0)

static inline void MxShowToast(NSString *message) {
    if (!message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = LeadTopPresenter();
        if (presenter.view) [LeadToast showText:message symbol:@"waveform" inView:presenter.view];
    });
}
