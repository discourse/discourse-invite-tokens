# name: discourse-invite-tokens
# about: Generate multiple invite tokens
# version: 0.1
# author: Arpit Jalan
# url: https://www.github.com/techAPJ/discourse-invite-tokens

enabled_site_setting :invite_tokens_enabled

PLUGIN_NAME = "discourse_invite_tokens".freeze

after_initialize do
  module ::DiscourseInviteTokens
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseInviteTokens
    end
  end

  require_dependency 'invite'
  class ::Invite

    def self.generate_disposable_tokens(invited_by, quantity=nil, group_names=nil)
      invite_tokens = []
      quantity ||= 1
      group_ids = get_group_ids(group_names)

      quantity.to_i.times do
        invite = Invite.create!(invited_by: invited_by)
        group_ids = group_ids - invite.invited_groups.pluck(:group_id)
        group_ids.each do |group_id|
          invite.invited_groups.create!(group_id: group_id)
        end
        invite_tokens.push(invite.invite_key)
      end

      invite_tokens
    end

    def self.redeem_from_token(token, email, username=nil, name=nil, topic_id=nil)
      invite = Invite.find_by(invite_key: token)
      if invite
        lower_email = Email.downcase(email)
        user = User.find_by(email: lower_email)
        raise UserExists.new I18n.t("invite.user_exists_simple") if user.present?

        invite.update_column(:email, email)
        invite.topic_invites.create!(invite_id: invite.id, topic_id: topic_id) if topic_id && Topic.find_by_id(topic_id) && !invite.topic_invites.pluck(:topic_id).include?(topic_id)
        user = InviteRedeemer.new(invite, username, name).redeem
      end
      user
    end
  end

  require_dependency "application_controller"
  class DiscourseInviteTokens::InviteTokensController < ::ApplicationController
   requires_plugin PLUGIN_NAME

   skip_before_filter :check_xhr
   skip_before_filter :preload_json
   skip_before_filter :redirect_to_login_if_required
   before_filter :ensure_logged_in, except: [:redeem_disposable_invite]

    def create_disposable_invite
      raise Discourse::InvalidAccess unless SiteSetting.invite_tokens_enabled? && guardian.is_admin?
      params.permit(:username, :email, :quantity, :group_names)

      username_or_email = params[:username] ? fetch_username : fetch_email
      user = User.find_by_username_or_email(username_or_email)

      invite_tokens = Invite.generate_disposable_tokens(user, params[:quantity], params[:group_names])
      render_json_dump(invite_tokens)
    end

    def redeem_disposable_invite
      return redirect_to path('/') unless SiteSetting.invite_tokens_enabled?
      params.require(:email)
      params.permit(:username, :name, :topic)
      params[:email] = params[:email].split(' ').join('+')
      invite = Invite.find_by(invite_key: params[:token])

      if invite.present?
        begin
          user = Invite.redeem_from_token(params[:token], params[:email], params[:username], params[:name], params[:topic].to_i)
          if user.present?
            log_on_user(user)
            post_process_invite(user)
          end

          topic = invite.topics.first
          topic = user.present? ? invite.topics.first : nil
          return redirect_to path("#{topic.relative_url}") if topic.present?

          redirect_to path("/")
        rescue Invite::UserExists, ActiveRecord::RecordInvalid => e
          render json: {errors: [e.message]}, status: 422
        end
      else
        render json: { success: false, message: I18n.t('invite.not_found') }
      end
    end

    def fetch_username
      params.require(:username)
      params[:username]
    end

    def fetch_email
      params.require(:email)
      params[:email]
    end

    def post_process_invite(user)
      user.enqueue_welcome_message('welcome_invite') if user.send_welcome_message
      if user.has_password?
        email_token = user.email_tokens.create(email: user.email)
        Jobs.enqueue(:critical_user_email, type: :signup, user_id: user.id, email_token: email_token.token)
      elsif !SiteSetting.enable_sso && SiteSetting.enable_local_logins
        Jobs.enqueue(:invite_password_instructions_email, username: user.username)
      end
    end
  end

  DiscourseInviteTokens::Engine.routes.draw do
    post "/generate" => "invite_tokens#create_disposable_invite"
    get "/redeem/:token" => "invite_tokens#redeem_disposable_invite"

  end

  Discourse::Application.routes.append do
    mount ::DiscourseInviteTokens::Engine, at: '/invite-token'
  end
end
