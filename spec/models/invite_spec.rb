# frozen_string_literal: true

require "rails_helper"

describe Invite do
  before { SiteSetting.invite_tokens_enabled = true }

  describe ".redeem_from_token" do
    let(:inviter) { Fabricate(:user) }
    let(:invite) { Fabricate(:invite, invited_by: inviter, email: "test@example.com") }
    let(:invalid_invite) do
      Fabricate(:invite, invited_by: inviter, email: "existing_user@example.com")
    end
    let(:existing_user) { Fabricate(:user, email: invite.email) }

    it "redeems the invite from token" do
      Invite.redeem_from_token(invite.invite_key, "test@example.com")
      invite.reload
      expect(invite).to be_redeemed
    end

    it "does not redeem the invite if token does not match" do
      Invite.redeem_from_token("bae0071f995bb4b6f756e80b383778b5", "user@example.com")
      invite.reload
      expect(invite).not_to be_redeemed
    end

    it "does not redeem the invite if user exists with that email" do
      expect {
        Invite.redeem_from_token(invalid_invite.invite_key, existing_user.email)
      }.to raise_error(Invite::UserExists)
    end
  end
end
