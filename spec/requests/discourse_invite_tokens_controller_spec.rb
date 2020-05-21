# frozen_string_literal: true

require 'rails_helper'

describe DiscourseInviteTokens do
  before do
    SiteSetting.invite_tokens_enabled = true
  end

  describe 'redeem_invite_token' do
    let(:user) { Fabricate(:coding_horror) }
    let(:invite) { Fabricate(:invite, invited_by: user, emailed_status: Invite.emailed_status_types[:not_required]) }
    context 'success' do

      before do
        SiteSetting.invite_tokens_requires_email_confirmation = false
      end

      it 'logs in the user' do
        events = DiscourseEvent.track_events do
          put "/invite-token/redeem/#{invite.invite_key}?email=foo@bar.com"
        end

        expect(events.map { |event| event[:event_name] }).to include(
          :user_logged_in, :user_first_logged_in
        )
        invite.reload

        expect(response.status).to eq(302)
        expect(session[:current_user_id]).to eq(invite.invited_users.first.user_id)
        expect(invite.redeemed?).to be_truthy

        invited_user = User.find(invite.invited_users.first.user_id)
        expect(invited_user.active).to eq(true)
        expect(invited_user.email_confirmed?).to eq(false)
      end
    end
  end
end
