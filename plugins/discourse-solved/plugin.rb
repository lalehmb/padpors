# name: discourse-solved
# about: Add a solved button to answers on Discourse
# version: 0.1
# authors: Sam Saffron

PLUGIN_NAME = "discourse_solved".freeze

register_asset 'stylesheets/solutions.scss'

after_initialize do

  module ::DiscourseSolved
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseSolved
    end
  end

  require_dependency "application_controller"
  class DiscourseSolved::AnswerController < ::ApplicationController
    def accept

      limit_accepts

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_accept_answer!(post.topic)

      accepted_id = post.topic.custom_fields["accepted_answer_post_id"].to_i
      if accepted_id > 0
        if p2 = Post.find_by(id: accepted_id)
          p2.custom_fields["is_accepted_answer"] = nil
          p2.save!
        end
      end

      post.custom_fields["is_accepted_answer"] = "true"
      post.topic.custom_fields["accepted_answer_post_id"] = post.id
      post.topic.save!
      post.save!

      unless current_user.id == post.user_id

        Notification.create!(notification_type: Notification.types[:custom],
                           user_id: post.user_id,
                           topic_id: post.topic_id,
                           post_number: post.post_number,
                           data: {
                             message: 'solved.accepted_notification',
                             display_username: current_user.username,
                             topic_title: post.topic.title
                           }.to_json
                          )
      end

      render json: success_json
    end

    def unaccept

      limit_accepts

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_accept_answer!(post.topic)

      post.custom_fields["is_accepted_answer"] = nil
      post.topic.custom_fields["accepted_answer_post_id"] = nil
      post.topic.save!
      post.save!

      # yank notification
      notification = Notification.find_by(
         notification_type: Notification.types[:custom],
         user_id: post.user_id,
         topic_id: post.topic_id,
         post_number: post.post_number
      )

      notification.destroy if notification

      render json: success_json
    end

    def limit_accepts
      unless current_user.staff?
        RateLimiter.new(nil, "accept-hr-#{current_user.id}", 20, 1.hour).performed!
        RateLimiter.new(nil, "accept-min-#{current_user.id}", 4, 30.seconds).performed!
      end
    end
  end

  DiscourseSolved::Engine.routes.draw do
    post "/accept" => "answer#accept"
    post "/unaccept" => "answer#unaccept"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseSolved::Engine, at: "solution"
  end

  TopicView.add_post_custom_fields_whitelister do |user|
    ["is_accepted_answer"]
  end

  if Report.respond_to?(:add_report)
    AdminDashboardData::GLOBAL_REPORTS << "accepted_solutions"

    Report.add_report("accepted_solutions") do |report|
      report.data = []
      accepted_solutions = TopicCustomField.where(name: "accepted_answer_post_id")
      accepted_solutions = accepted_solutions.joins(:topic).where("topics.category_id = ?", report.category_id) if report.category_id
      accepted_solutions.where("topic_custom_fields.created_at >= ?", report.start_date)
                        .where("topic_custom_fields.created_at <= ?", report.end_date)
                        .group("DATE(topic_custom_fields.created_at)")
                        .order("DATE(topic_custom_fields.created_at)")
                        .count
                        .each do |date, count|
        report.data << { x: date, y: count }
      end
      report.total = accepted_solutions.count
      report.prev30Days = accepted_solutions.where("topic_custom_fields.created_at >= ?", report.start_date - 30.days)
                                            .where("topic_custom_fields.created_at <= ?", report.start_date)
                                            .count
    end
  end

  require_dependency 'topic_view_serializer'
  class ::TopicViewSerializer
    attributes :accepted_answer

    def include_accepted_answer?
      accepted_answer_post_id
    end

    def accepted_answer
      if info = accepted_answer_post_info
        {
          post_number: info[0],
          username: info[1],
        }
      end
    end

    def accepted_answer_post_info
      # TODO: we may already have it in the stream ... so bypass query here

      Post.where(id: accepted_answer_post_id, topic_id: object.topic.id)
          .joins(:user)
          .pluck('post_number, username')
          .first
    end

    def accepted_answer_post_id
      id = object.topic.custom_fields["accepted_answer_post_id"]
      # a bit messy but race conditions can give us an array here, avoid
      id && id.to_i rescue nil
    end

  end

  class ::Category
    after_save :reset_accepted_cache

    protected
    def reset_accepted_cache
      ::Guardian.reset_accepted_answer_cache
    end
  end

  class ::Guardian

    @@allowed_accepted_cache = DistributedCache.new("allowed_accepted")

    def self.reset_accepted_answer_cache
      @@allowed_accepted_cache["allowed"] =
        begin
          Set.new(
            CategoryCustomField
              .where(name: "enable_accepted_answers", value: "true")
              .pluck(:category_id)
          )
        end
    end

    def allow_accepted_answers_on_category?(category_id)
      return true if SiteSetting.allow_solved_on_all_topics

      self.class.reset_accepted_answer_cache unless @@allowed_accepted_cache["allowed"]
      @@allowed_accepted_cache["allowed"].include?(category_id)
    end

    def can_accept_answer?(topic)
      allow_accepted_answers_on_category?(topic.category_id) && (
        is_staff? || (
          authenticated? && !topic.closed? && topic.user_id == current_user.id
        )
      )
    end
  end

  require_dependency 'post_serializer'
  class ::PostSerializer
    attributes :can_accept_answer, :can_unaccept_answer, :accepted_answer

    def can_accept_answer
      topic = (topic_view && topic_view.topic) || object.topic

      if topic
        return scope.can_accept_answer?(topic) && object.post_number > 1 && !accepted_answer
      end

      false
    end

    def can_unaccept_answer
      topic = (topic_view && topic_view.topic) || object.topic
      if topic
        return scope.can_accept_answer?(topic) && (post_custom_fields["is_accepted_answer"] == 'true')
      end
    end

    def accepted_answer
      post_custom_fields["is_accepted_answer"] == 'true'
    end
  end

  require_dependency 'search'

  #TODO Remove when plugin is 1.0
  if Search.respond_to? :advanced_filter
    Search.advanced_filter(/in:solved/) do |posts|
      posts.where("topics.id IN (
        SELECT tc.topic_id
        FROM topic_custom_fields tc
        WHERE tc.name = 'accepted_answer_post_id' AND
                        tc.value IS NOT NULL
        )")

    end

    Search.advanced_filter(/in:unsolved/) do |posts|
      posts.where("topics.id NOT IN (
        SELECT tc.topic_id
        FROM topic_custom_fields tc
        WHERE tc.name = 'accepted_answer_post_id' AND
                        tc.value IS NOT NULL
        )")

    end
  end

  require_dependency 'topic_list_item_serializer'

  class ::TopicListItemSerializer
    attributes :has_accepted_answer

    def include_has_accepted_answer?
      object.custom_fields["accepted_answer_post_id"]
    end

    def has_accepted_answer
      true
    end
  end

  TopicList.preloaded_custom_fields << "accepted_answer_post_id" if TopicList.respond_to? :preloaded_custom_fields

end
