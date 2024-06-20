# frozen_string_literal: true

class ProblemCheck::DeprecatedInviteTokens < ProblemCheck
  self.priority = "low"

  def call
    return no_problem if !SiteSetting.invite_tokens_enabled

    problem
  end

  private

  def message
    "The discourse-invite-tokens plugin has been integrated into discourse core. Please remove the plugin from your app.yml and rebuild your container."
  end
end
