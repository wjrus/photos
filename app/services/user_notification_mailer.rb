class UserNotificationMailer
  class << self
    def invitation(user)
      url = routes.invitation_url(user.invitation_url_token, url_options)
      MailgunClient.deliver(
        to: user.email,
        subject: "You are invited to view photos",
        text: invitation_text(user, url),
        html: simple_html(invitation_text(user, url))
      )
    end

    def password_reset(user, token)
      url = routes.edit_password_reset_url(token, url_options)
      MailgunClient.deliver(
        to: user.email,
        subject: "Reset your photos password",
        text: password_reset_text(user, url),
        html: simple_html(password_reset_text(user, url))
      )
    end

    private

    def routes
      Rails.application.routes.url_helpers
    end

    def url_options
      Rails.application.config.action_mailer.default_url_options
    end

    def invitation_text(user, url)
      <<~TEXT
        Hi #{user.display_name},

        You have been invited to view shared photos.

        Open this link to accept the invitation:
        #{url}

        If you were not expecting this invitation, you can ignore this message.
      TEXT
    end

    def password_reset_text(user, url)
      <<~TEXT
        Hi #{user.display_name},

        Open this link to set a new password:
        #{url}

        The link can be opened safely by mail scanners. Your reset token is not used until a new password is successfully saved.

        If you did not request this, you can ignore this message.
      TEXT
    end

    def simple_html(text)
      paragraphs = text.split(/\n{2,}/).map do |paragraph|
        ERB::Util.html_escape(paragraph).gsub("\n", "<br>")
      end

      paragraphs.map { |paragraph| "<p>#{paragraph}</p>" }.join
    end
  end
end
