#pragma once

#include "KeyboardLayout.h"
#import <Carbon/Carbon.h>

// Main-thread only. Reading a source never selects it or changes system settings.
bawan::KeyboardLayout KeyboardLayoutForInputSource(TISInputSourceRef source, UInt32 keyboardType);
bawan::KeyboardLayout CurrentKeyboardLayout();
