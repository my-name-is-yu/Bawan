#pragma once

#include "TranslationPrompt.h"

namespace lore::detail {

// Defined by the evaluation executable, never linked into Lore.app.
PromptOptions evaluationPrompt(std::string_view text, bool toEnglish);

} // namespace lore::detail
