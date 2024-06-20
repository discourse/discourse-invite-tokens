# frozen_string_literal: true

# name: discourse-invite-tokens
# about: Generate multiple invite tokens
# version: 0.2
# author: Arpit Jalan
# url: https://github.com/discourse/discourse-invite-tokens

enabled_site_setting :invite_tokens_enabled

after_initialize do
  require_relative "app/services/problem_check/deprecated_invite_tokens"
  register_problem_check ProblemCheck::DeprecatedInviteTokens

  module ::DiscourseInviteTokens
    PLUGIN_NAME = "discourse-invite-tokens"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseInviteTokens
    end
  end

  require_relative "lib/discourse_invite_tokens/invite_extension"

  reloadable_patch { Invite.prepend(DiscourseInviteTokens::InviteExtension) }

  require_dependency "application_controller"
  class DiscourseInviteTokens::InviteTokensController < ::ApplicationController
    requires_plugin DiscourseInviteTokens::PLUGIN_NAME

    skip_before_action :check_xhr
    skip_before_action :preload_json
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_logged_in, only: [:create_invite_token]
    before_action :ensure_not_logged_in, only: %i[show redeem_invite_token]
    before_action :ensure_new_registrations_allowed, only: %i[show redeem_invite_token]

    def show
      prepend_view_path "plugins/discourse-invite-tokens/app/views/"
      expires_now

      return redirect_to path("/") unless SiteSetting.invite_tokens_enabled?
      params.require(:email)
      params.permit(:username, :name, :topic)
      params[:email] = params[:email].split(" ").join("+")
      invite = Invite.find_by(invite_key: params[:token])

      if invite.present? && !invite.redeemed?
        if (EmailAddressValidator.email_regex =~ params[:email])
          @email = params[:email]
          @username = params[:username]
          @name = params[:name]
          @topic = params[:topic]
        else
          flash.now[:error] = I18n.t("invite.invalid_email_address")
        end
      else
        flash.now[:error] = I18n.t(
          "invite.not_found_template",
          site_name: SiteSetting.title,
          base_url: Discourse.base_url,
        )
      end
      render layout: "no_ember"
    end

    def redeem_invite_token
      return redirect_to path("/") unless SiteSetting.invite_tokens_enabled?
      params.require(:email)
      params.permit(:username, :name, :topic)
      params[:email] = params[:email].split(" ").join("+")
      invite = Invite.find_by(invite_key: params[:token])

      if invite.present?
        begin
          user =
            Invite.redeem_from_token(
              params[:token],
              params[:email],
              params[:username],
              params[:name],
              params[:topic].to_i,
            )
          if user.present?
            unless SiteSetting.invite_tokens_requires_email_confirmation?
              user.update_column(:active, true)
            end
            log_on_user(user) if user.active?
            post_process_invite(user)
          end

          if user.present? && user.active?
            topic = invite.topics.first
            return redirect_to path("#{topic.relative_url}") if topic.present?
            redirect_to path("/")
          else
            flash.now[:info] = I18n.t("invite.confirm_email")
            render layout: "no_ember"
          end
        rescue Invite::UserExists, ActiveRecord::RecordInvalid => e
          render json: { errors: [e.message] }, status: 422
        end
      else
        render json: { success: false, message: I18n.t("invite.not_found") }
      end
    end

    def create_invite_token
      raise Discourse::InvalidAccess unless SiteSetting.invite_tokens_enabled? && guardian.is_admin?
      params.permit(:username, :email, :quantity, :group_names)

      username_or_email = params[:username] ? fetch_username : fetch_email
      user = User.find_by_username_or_email(username_or_email)

      invite_tokens = Invite.generate_invite_tokens(user, params[:quantity], params[:group_names])
      render_json_dump(invite_tokens)
    end

    def ensure_new_registrations_allowed
      prepend_view_path "plugins/discourse-invite-tokens/app/views/"
      unless SiteSetting.allow_new_registrations
        flash[:error] = I18n.t("login.new_registrations_disabled")
        render layout: "no_ember"
        false
      end
    end

    def ensure_not_logged_in
      prepend_view_path "plugins/discourse-invite-tokens/app/views/"
      if current_user
        flash[:error] = I18n.t("login.already_logged_in", current_user: current_user.username)
        render layout: "no_ember"
        false
      end
    end

    private

    def fetch_username
      params.require(:username)
      params[:username]
    end

    def fetch_email
      params.require(:email)
      params[:email]
    end

    def post_process_invite(user)
      user.enqueue_welcome_message("welcome_invite") if user.send_welcome_message
      if user.has_password?
        email_token = user.email_tokens.create(email: user.email)
        Jobs.enqueue(
          :critical_user_email,
          type: :signup,
          user_id: user.id,
          email_token: email_token.token,
        )
      elsif !SiteSetting.enable_discourse_connect && SiteSetting.enable_local_logins
        Jobs.enqueue(:invite_password_instructions_email, username: user.username)
      end
    end
  end

  DiscourseInviteTokens::Engine.routes.draw do
    post "/generate" => "invite_tokens#create_invite_token"
    get "/redeem/:token" => "invite_tokens#show"
    put "redeem/:token" => "invite_tokens#redeem_invite_token", :as => "redeem_invite_token"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseInviteTokens::Engine, at: "/invite-token"
  end
end
