class UserNotificationMailer
  class << self
    def invitation(user)
      url = routes.invitation_url(user.invitation_url_token, url_options)
      MailgunClient.deliver(
        to: user.email,
        subject: "William shared photos with you",
        text: invitation_text(user, url),
        html: invitation_html(user, url)
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

        You have been invited to sign in and view private photo galleries William Rockwood has shared with you.

        View the photos:
        #{url}

        If you were not expecting this invitation, you can ignore this message.
      TEXT
    end

    def invitation_html(user, url)
      escaped_name = escape(user.display_name)
      escaped_url = escape(url)
      icon_url = escape(public_url("/icon.png"))

      <<~HTML
        <!doctype html>
        <html>
          <body style="margin:0;background:#f8f7f4;color:#18181b;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
            <div style="display:none;max-height:0;overflow:hidden;color:transparent;">
              You have been invited to sign in and view private photo galleries William Rockwood has shared with you.
            </div>
            <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f8f7f4;padding:32px 16px;">
              <tr>
                <td align="center">
                  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#ffffff;border:1px solid #e4e4e7;border-radius:14px;overflow:hidden;box-shadow:0 2px 8px rgba(24,24,27,0.06);">
                    <tr>
                      <td style="padding:28px 28px 8px;text-align:center;">
                        <img src="#{icon_url}" width="56" height="56" alt="" style="display:inline-block;width:56px;height:56px;border-radius:12px;border:1px solid #e4e4e7;box-shadow:0 1px 3px rgba(24,24,27,0.15);">
                        <p style="margin:18px 0 0;font-size:12px;font-weight:700;letter-spacing:0.22em;text-transform:uppercase;color:#0f766e;">wjr photos</p>
                        <h1 style="margin:10px 0 0;font-size:28px;line-height:1.15;font-weight:700;color:#09090b;">William shared photos with you</h1>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:12px 28px 4px;">
                        <p style="margin:0;font-size:16px;line-height:1.6;color:#3f3f46;">Hi #{escaped_name},</p>
                        <p style="margin:14px 0 0;font-size:16px;line-height:1.6;color:#3f3f46;">You have been invited to sign in and view private photo galleries William Rockwood has shared with you.</p>
                      </td>
                    </tr>
                    <tr>
                      <td align="center" style="padding:24px 28px;">
                        <a href="#{escaped_url}" style="display:inline-block;border-radius:10px;background:#09090b;color:#ffffff;font-size:15px;font-weight:700;text-decoration:none;padding:13px 20px;">View photos</a>
                      </td>
                    </tr>
                    <tr>
                      <td style="padding:0 28px 28px;">
                        <p style="margin:0;font-size:13px;line-height:1.6;color:#71717a;">If the button does not work, open this link:</p>
                        <p style="margin:6px 0 0;font-size:13px;line-height:1.6;word-break:break-all;"><a href="#{escaped_url}" style="color:#0f766e;text-decoration:underline;">#{escaped_url}</a></p>
                      </td>
                    </tr>
                  </table>
                  <p style="margin:16px 0 0;font-size:12px;line-height:1.6;color:#71717a;">If you were not expecting this invitation, you can ignore this message.</p>
                </td>
              </tr>
            </table>
          </body>
        </html>
      HTML
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
        escape(paragraph).gsub("\n", "<br>")
      end

      paragraphs.map { |paragraph| "<p>#{paragraph}</p>" }.join
    end

    def public_url(path)
      URI.join(routes.root_url(url_options_with_protocol), path).to_s
    end

    def url_options_with_protocol
      url_options.with_defaults(protocol: Rails.env.production? ? "https" : "http")
    end

    def escape(value)
      ERB::Util.html_escape(value)
    end
  end
end
