# frozen_string_literal: true

module DiscourseInviteTokens
  module InviteExtension
    extend ActiveSupport::Concern

    class_methods do
      def generate_invite_tokens(invited_by, quantity = nil, group_names = nil)
        invite_tokens = []
        quantity ||= 1
        group_ids = get_group_ids(group_names)

        quantity.to_i.times do
          invite =
            Invite.create!(
              invited_by: invited_by,
              emailed_status: Invite.emailed_status_types[:not_required],
            )
          group_ids = group_ids - invite.invited_groups.pluck(:group_id)
          group_ids.each { |group_id| invite.invited_groups.create!(group_id: group_id) }
          invite_tokens.push(invite.invite_key)
        end

        invite_tokens
      end

      def redeem_from_token(token, email, username = nil, name = nil, topic_id = nil)
        invite = Invite.find_by(invite_key: token)
        if invite
          lower_email = Email.downcase(email)
          user = User.find_by_email(lower_email)
          raise Invite::UserExists.new I18n.t("invite.user_exists_simple") if user.present?

          if topic_id && Topic.find_by_id(topic_id) &&
               !invite.topic_invites.pluck(:topic_id).include?(topic_id)
            invite.topic_invites.create!(invite_id: invite.id, topic_id: topic_id)
          end
          user =
            InviteRedeemer.new(invite: invite, email: email, username: username, name: name).redeem
        end
        user
      end
    end
  end
end
