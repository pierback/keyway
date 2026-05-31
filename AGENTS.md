## Code Standards
The program must crash if users do something stupid, so no 'try/except and no fallbacks without explicit
approval in prompt. Dependencies and stdlib already raise proper exceptions that are enough for debugging
and control flow, so do not add any exception handling if you use them unless prompt explicitely asks you.
Do not use Rue custom exceptions unless prompt explicitely asks you. Cleanup 'try/finally" is fine when
lifecycle ownership requires it.
Clean code is not optional. Less code is better than more code. Fewer models are better than more models.
Helper spam is a red flag. Model spam is a red flag. Do not add a helper when the inline code is one or
two lines, even if it repeats ten times. DRY is a tool, not a religion.
Do not add convenient wrapper properties. Consumers should request the real thing directly. Do not wrap
dependencies or stdlibs into APIs, call them directly.