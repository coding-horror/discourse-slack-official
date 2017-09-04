module DiscourseSlack
  class Slack
    KEY_PREFIX = 'category_'.freeze

    def self.filter_to_present(filter)
      I18n.t("slack.command.present.#{filter}")
    end

    def self.filter_to_past(filter)
      I18n.t("slack.command.past.#{filter}")
    end

    def self.excerpt(post, max_length = SiteSetting.slack_discourse_excerpt_length)
      doc = Nokogiri::HTML.fragment(post.excerpt(max_length,
        remap_emoji: true,
        keep_onebox_source: true
      ))

      SlackMessageFormatter.format(doc.to_html)
    end

    def self.format_channel(name)
      (name.include?("@") || name.include?("\#")) ? name : "<##{name}>"
    end

    def self.format_tags(names)
      return "" unless SiteSetting.tagging_enabled? && names.present?

      I18n.t("slack.message.status.with_tags", tags: names.join(", "))
    end

    def self.available_categories
      cat_list = (CategoryList.new(guardian).categories.map { |category| category.slug }).join(', ')
      I18n.t("slack.message.available_categories", list: cat_list)
    end

    def self.status(channel)
      rows = PluginStoreRow.where(plugin_name: DiscourseSlack::PLUGIN_NAME).where("key ~* :pat", pat: '^category_.*')
      text = ""

      categories = rows.map { |item| item.key.gsub('category_', '') }

      Category.where(id: categories).each do | category |
        get_store_by_channel(channel, category.id).each do |row|
          text << I18n.t("slack.message.status.category",
                          command: filter_to_present(row[:filter]),
                          name: category.name)
          text << format_tags(row[:tags]) << "\n"
        end
      end

      get_store_by_channel(channel).each do |row|
        text << I18n.t("slack.message.status.all_categories",
                        command: filter_to_present(row[:filter]))
        text << format_tags(row[:tags]) << "\n"
      end
      text << available_categories
      text
    end

    def self.guardian
      Guardian.new(User.find_by(username: SiteSetting.slack_discourse_username))
    end

    def self.help
      I18n.t("slack.help")
    end

    def self.slack_message(post, channel)
      display_name = "@#{post.user.username}"
      full_name = post.user.name || ""

      if !(full_name.strip.empty?) && (full_name.strip.gsub(' ', '_').casecmp(post.user.username) != 0) && (full_name.strip.gsub(' ', '').casecmp(post.user.username) != 0)
        display_name = "#{full_name} @#{post.user.username}"
      end

      topic = post.topic

      category = (topic.category.parent_category) ? "[#{topic.category.parent_category.name}/#{topic.category.name}]" : "[#{topic.category.name}]"

      icon_url =
        if !SiteSetting.slack_icon_url.blank?
          SiteSetting.slack_icon_url
        elsif !SiteSetting.logo_small_url.blank?
          "#{Discourse.base_url}#{SiteSetting.logo_small_url}"
        end

      message = {
        channel: channel,
        username: SiteSetting.title,
        icon_url: icon_url,
        attachments: []
      }

      summary = {
        fallback: "#{topic.title} - #{display_name}",
        author_name: display_name,
        author_icon: post.user.small_avatar_url,
        color: "##{topic.category.color}",
        text: ::DiscourseSlack::Slack.excerpt(post),
        mrkdwn_in: ["text"]
      }

      record = ::PluginStore.get(DiscourseSlack::PLUGIN_NAME, "topic_#{post.topic.id}_#{channel}")

      if (SiteSetting.slack_access_token.empty? || post.is_first_post? || record.blank? || (record.present? && ((Time.now.to_i - record[:ts].split('.')[0].to_i) / 60) >= 5))
        summary[:title] = "#{topic.title} #{(category == '[uncategorized]') ? '' : category} #{topic.tags.present? ? topic.tags.map(&:name).join(', ') : ''}"
        summary[:title_link] = post.full_url
        summary[:thumb_url] = post.full_url
      end

      message[:attachments].push(summary)
      message
    end

    def self.get_key(id = nil)
      "#{KEY_PREFIX}#{id.present? ? id : '*'}"
    end

    def self.update_tag_filter(channel, filter, tag)
      data = get_store(nil)
      to_delete = []

      index = data.index do |item|
        next unless item["channel"] == channel
        if item["tags"]
          item["tags"] = item["tags"] - [tag]
          to_delete << item if item["tags"].empty?
        end
        item["tags"] && item["filter"] == filter
      end

      if filter != "unset"
        data[index]['tags'].push(tag) if index
        data.push(channel: channel, filter: filter, tags: [tag]) if !index
      end

      data = data - to_delete
      PluginStore.set(DiscourseSlack::PLUGIN_NAME, get_key(nil), data)
    end

    def self.update_all_filter(channel, filter)
      update_category_filter(channel, filter, nil)
    end

    def self.update_category_filter(channel, filter, category_id)
      data = get_store(category_id)
      index = data.index do |item|
        item["channel"] == channel && !item["tags"]
      end

      if index && filter == "unset"
        data.delete data[index]
      end

      if filter != "unset"
        data[index]['filter'] = filter if index
        data.push(channel: channel, filter: filter, tags: nil) if !index
      end

      PluginStore.set(DiscourseSlack::PLUGIN_NAME, get_key(category_id), data)
    end

    def self.create_filter(category_id, channel, filter, tags)
      data = get_store(category_id)
      tags = Tag.where(name: tags).pluck(:name)
      tags = nil if tags.blank?

      data.push(channel: channel, filter: filter, tags: tags)
      PluginStore.set(DiscourseSlack::PLUGIN_NAME, get_key(category_id), data)
    end

    def self.delete_filter(category_id, channel, tags)
      data = get_store(category_id)
      tags = nil if tags.blank?

      data.delete_if do |i|
        i['channel'] == channel && i['tags'] == tags
      end

      if data.empty?
        PluginStore.remove(DiscourseSlack::PLUGIN_NAME, get_key(category_id))
      else
        PluginStore.set(DiscourseSlack::PLUGIN_NAME, get_key(category_id), data)
      end
    end

    def self.get_store(category_id = nil)
      PluginStore.get(DiscourseSlack::PLUGIN_NAME, get_key(category_id)) || []
    end

    def self.get_store_by_channel(channel, category_id = nil)
      get_store(category_id).select { |r| format_channel(r[:channel]) == channel }
    end

    def self.notify(post_id)
      post = Post.find_by(id: post_id)
      return if post.blank? || post.post_type != Post.types[:regular] || !guardian.can_see?(post)

      topic = post.topic
      return if topic.blank? || topic.archetype == Archetype.private_message

      http = Net::HTTP.new(SiteSetting.slack_access_token.empty? ? "hooks.slack.com" : "slack.com" , 443)
      http.use_ssl = true

      precedence = { 'mute' => 0, 'watch' => 1, 'follow' => 1 }

      uniq_func = proc { |i| i.values_at(:channel, :tags) }
      sort_func = proc { |a, b| precedence[a] <=> precedence[b] }

      items = get_store(topic.category_id) | get_store
      responses = []

      items.sort_by(&sort_func).uniq(&uniq_func).each do |i|
        topic_tags = (SiteSetting.tagging_enabled? && topic.tags.present?) ? topic.tags.pluck(:name) : []

        next if SiteSetting.tagging_enabled? && i[:tags].present? && (topic_tags & i[:tags]).count == 0
        next if (i[:filter] == 'mute') || (!(post.is_first_post?) && i[:filter] == 'follow')

        message = slack_message(post, i[:channel])

        if !(SiteSetting.slack_access_token.empty?)
          response = nil
          uri = ""
          record = ::PluginStore.get(DiscourseSlack::PLUGIN_NAME, "topic_#{post.topic.id}_#{i[:channel]}")

          if (record.present? && ((Time.now.to_i - record[:ts].split('.')[0].to_i) / 60) < 5 && record[:message][:attachments].length < 5)
            attachments = record[:message][:attachments]
            attachments.concat message[:attachments]

            uri = URI("https://slack.com/api/chat.update" +
              "?token=#{SiteSetting.slack_access_token}" +
              "&username=#{CGI::escape(record[:message][:username])}" +
              "&text=#{CGI::escape(record[:message][:text])}" +
              "&channel=#{record[:channel]}" +
              "&attachments=#{CGI::escape(attachments.to_json)}" +
              "&ts=#{record[:ts]}"
            )
          else
            uri = URI("https://slack.com/api/chat.postMessage" +
              "?token=#{SiteSetting.slack_access_token}" +
              "&username=#{CGI::escape(message[:username])}" +
              "&icon_url=#{CGI::escape(message[:icon_url])}" +
              "&channel=#{ message[:channel].gsub('#', '') }" +
              "&attachments=#{CGI::escape(message[:attachments].to_json)}"
            )
          end

          response = http.request(Net::HTTP::Post.new(uri))

          ::PluginStore.set(DiscourseSlack::PLUGIN_NAME, "topic_#{post.topic.id}_#{i[:channel]}", JSON.parse(response.body))
        elsif !(SiteSetting.slack_outbound_webhook_url.empty?)
          req = Net::HTTP::Post.new(URI(SiteSetting.slack_outbound_webhook_url), 'Content-Type' => 'application/json')
          req.body = message.to_json
          response = http.request(req)
        end

        responses.push(response.body) if response
      end

      responses
    end
  end
end
