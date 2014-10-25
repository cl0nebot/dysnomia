class Event < ActiveRecord::Base
  include PublicActivity::Common
  include Tenanted
  include IceCube
  include Postprocess
  include PublishCrudEvents

  acts_as_processable :description

  # Unread
  acts_as_readable on: :created_at

  validates :starts_at, timeliness: { :type => :datetime } 
  validates :ends_at, timeliness: { :after => :starts_at, :type => :datetime } 
  validates :title, presence: true, length: { maximum: 500 }
  validates :category_id, presence: true

  has_many :participations
  has_many :users, through: :participations
  belongs_to :category
  belongs_to :tenant

  after_initialize :load_schedule_obj
  before_save :generate_schedule
  serialize :schedule, Hash
  attr_reader :schedule_obj

  composed_of :recurring_until, class_name: 'Date', mapping: %w(Date to_s), constructor: proc{ |o| o }, converter: proc{ |o| o }

  # need to override the json view to return what full_calendar is expecting.
  # http://arshaw.com/fullcalendar/docs/event_data/Event_Object/
  def as_json(options = {})
    {
      :id => self.id,
      :title => self.title,
      :description => self.description || "",
      :start => starts_at.rfc822,
      :end => ends_at.rfc822,
      :allDay => all_day?,
      :recurring => recurring?,
      :color => category.color,
      :url => relative_url
    }
  end

  def relative_url
    Rails.application.routes.url_helpers.event_path(id, params: {date: starts_at})
  end

  def absolute_url
    tenant.url + relative_url
  end

  def recurring?
    !schedule.empty?
  end

  def self.as_calendar(events)
    calendar = Icalendar::Calendar.new
    events.each do |e|
      calendar.event do |ce|
        ce.dtstart = e.starts_at.strftime("%Y%m%dT%H%M%S")
        ce.dtend = e.ends_at.strftime("%Y%m%dT%H%M%S")
        ce.created = e.created_at.strftime("%Y%m%dT%H%M%S")
        ce.last_modified = e.updated_at.strftime("%Y%m%dT%H%M%S")
        ce.summary = e.title
        ce.description = e.postprocessed_description
        ce.location = e.location
        ce.ip_class = "CONFIDENTIAL"
        ce.categories = [e.category.title]
        ce.url = e.absolute_url
        ce.uid = e.absolute_url

        e.users.each do |u|
          ce.append_attendee "mailto:#{u.email}"
        end

        if e.recurring?
          ce.rrule = e.schedule_obj.recurrence_rules.map { |r| r.to_ical }
          ce.exdate = e.schedule_obj.exception_times.map { |ex| ex.to_datetime }
        end
      end
    end
    calendar.publish
    calendar.to_ical
  end
  
  def self.between after, before
    after, before = [after, before].map! { |d| Time.at(d.to_i) }
    events = self.where("starts_at BETWEEN :after AND :before OR ends_at BETWEEN :after AND :before", {
      after: after.to_formatted_s(:db),
      before: before.to_formatted_s(:db)
    }).reject { |e| e.recurring? } + self.where.not(schedule: {}.to_yaml).map do |e|
      e.occurences_between(after, before)
    end.flatten
  end

  def occurences_between(after, before)
    unless recurring?
      (starts_at > after and starts_at < before) ? [self] : []
    else
      schedule_obj.occurrences_between(after, before).inject([]) do |events,o|
        events << Event.new(attributes).tap do |e|
          e.starts_at = o
          e.ends_at = o + (e.ends_at - e.starts_at)
        end
      end
    end
  end

  def add_exception date
    schedule_exceptions << date
    generate_schedule
  end

  def recurring_type
    if recurring?
      rule = @schedule_obj.recurrence_rules.first

      %w(weekly daily monthly).each do |type|
        @recurring_type ||= type if rule.is_a? "IceCube::#{type.camelcase}Rule".constantize
      end
    end

    @recurring_type
  end

  def recurring_type= type
    @recurring_type = type
    generate_schedule
  end

  def recurring_until
    @recurring_until ||= recurring? ? @schedule_obj.recurrence_rules.first.until_time : nil
  end

  def recurring_until= recurring_until
    @recurring_until = recurring_until
    generate_schedule
  end

  def schedule_exceptions
    @schedule_exceptions ||= recurring? ? @schedule_obj.exception_times : []
  end

  def schedule_exceptions= exceptions
    @schedule_exceptions = exceptions
    generate_schedule
  end

  private

  def load_schedule_obj
    @schedule_obj = Schedule.from_hash(schedule) if recurring?
  end

  def generate_schedule
    new_schedule = unless recurring_type.nil? or recurring_type.empty?
      Schedule.new(starts_at) do |s|
        rule = Rule.send(recurring_type)
        rule = rule.until(@recurring_until) unless @recurring_until.nil?
        s.add_recurrence_rule(rule)
        schedule_exceptions.map do |e|
          e.to_s
        end.each do |e|
          s.add_exception_time e.to_time unless e.empty?
        end
      end.to_hash 
    else
      {}
    end
    @schedule_obj = Schedule.from_hash(new_schedule)
    write_attribute :schedule, new_schedule
  end
end
