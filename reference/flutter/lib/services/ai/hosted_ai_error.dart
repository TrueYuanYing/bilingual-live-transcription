/// Only a locally translated, public message may cross the hosted API boundary.
class HostedAiError extends StateError {
  HostedAiError(super.message);
}
