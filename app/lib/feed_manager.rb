# frozen_string_literal: true

require 'singleton'

class FeedManager
  include Singleton

  MAX_ITEMS = 400

  # Must be <= MAX_ITEMS or the tracking sets will grow forever
  REBLOG_FALLOFF = 40

  def key(type, id, subtype = nil)
    return "feed:#{type}:#{id}" unless subtype

    "feed:#{type}:#{id}:#{subtype}"
  end

  def filter?(timeline_type, status, receiver_id)
    if timeline_type == :home
      filter_from_home?(status, receiver_id)
    elsif timeline_type == :mentions
      filter_from_mentions?(status, receiver_id)
    else
      false
    end
  end

  def push_to_home(account, status)
    return false unless add_to_feed(:home, account.id, status)
    trim(:home, account.id)
    PushUpdateWorker.perform_async(account.id, status.id, "timeline:#{account.id}") if push_update_required?("timeline:#{account.id}")
    true
  end

  def unpush_from_home(account, status)
    return false unless remove_from_feed(:home, account.id, status)
    Redis.current.publish("timeline:#{account.id}", Oj.dump(event: :delete, payload: status.id.to_s))
    true
  end

  def push_to_list(list, status)
    return false unless add_to_feed(:list, list.id, status)
    trim(:list, list.id)
    PushUpdateWorker.perform_async(list.account_id, status.id, "timeline:list:#{list.id}") if push_update_required?("timeline:list:#{list.id}")
    true
  end

  def unpush_from_list(list, status)
    return false unless remove_from_feed(:list, list.id, status)
    Redis.current.publish("timeline:list:#{list.id}", Oj.dump(event: :delete, payload: status.id.to_s))
    true
  end

  def trim(type, account_id)
    timeline_key = key(type, account_id)
    reblog_key   = key(type, account_id, 'reblogs')

    # Remove any items past the MAX_ITEMS'th entry in our feed
    redis.zremrangebyrank(timeline_key, '0', (-(FeedManager::MAX_ITEMS + 1)).to_s)

    # Get the score of the REBLOG_FALLOFF'th item in our feed, and stop
    # tracking anything after it for deduplication purposes.
    falloff_rank  = FeedManager::REBLOG_FALLOFF - 1
    falloff_range = redis.zrevrange(timeline_key, falloff_rank, falloff_rank, with_scores: true)
    falloff_score = falloff_range&.first&.last&.to_i || 0

    # Get any reblogs we might have to clean up after.
    redis.zrangebyscore(reblog_key, 0, falloff_score).each do |reblogged_id|
      # Remove it from the set of reblogs we're tracking *first* to avoid races.
      redis.zrem(reblog_key, reblogged_id)
      # Just drop any set we might have created to track additional reblogs.
      # This means that if this reblog is deleted, we won't automatically insert
      # another reblog, but also that any new reblog can be inserted into the
      # feed.
      redis.del(key(type, account_id, "reblogs:#{reblogged_id}"))
    end
  end

  def merge_into_timeline(from_account, into_account)
    timeline_key = key(:home, into_account.id)
    query        = from_account.statuses.limit(FeedManager::MAX_ITEMS / 4)

    if redis.zcard(timeline_key) >= FeedManager::MAX_ITEMS / 4
      oldest_home_score = redis.zrange(timeline_key, 0, 0, with_scores: true)&.first&.last&.to_i || 0
      query = query.where('id > ?', oldest_home_score)
    end

    query.each do |status|
      next if status.direct_visibility? || filter?(:home, status, into_account)
      add_to_feed(:home, into_account.id, status)
    end

    trim(:home, into_account.id)
  end

  def unmerge_from_timeline(from_account, into_account)
    timeline_key      = key(:home, into_account.id)
    oldest_home_score = redis.zrange(timeline_key, 0, 0, with_scores: true)&.first&.last&.to_i || 0

    from_account.statuses.select('id, reblog_of_id').where('id > ?', oldest_home_score).reorder(nil).find_each do |status|
      remove_from_feed(:home, into_account.id, status)
    end
  end

  def clear_from_timeline(account, target_account)
    timeline_key        = key(:home, account.id)
    timeline_status_ids = redis.zrange(timeline_key, 0, -1)
    target_statuses     = Status.where(id: timeline_status_ids, account: target_account)

    target_statuses.each do |status|
      unpush_from_home(account, status)
    end
  end

  def populate_feed(account)
    added  = 0
    limit  = FeedManager::MAX_ITEMS / 2
    max_id = nil

    loop do
      statuses = Status.as_home_timeline(account)
                       .paginate_by_max_id(limit, max_id)

      break if statuses.empty?

      statuses.each do |status|
        next if filter_from_home?(status, account)
        added += 1 if add_to_feed(:home, account.id, status)
      end

      break unless added.zero?

      max_id = statuses.last.id
    end
  end

  private

  def redis
    Redis.current
  end

  def push_update_required?(timeline_id)
    redis.exists("subscribed:#{timeline_id}")
  end

  def filter_from_home?(status, receiver_id)
    return false if receiver_id == status.account_id
    return true  if status.reply? && (status.in_reply_to_id.nil? || status.in_reply_to_account_id.nil?)

    check_for_mutes = [status.account_id]
    check_for_mutes.concat([status.reblog.account_id]) if status.reblog?

    return true if Mute.where(account_id: receiver_id, target_account_id: check_for_mutes).any?

    check_for_blocks = status.mentions.pluck(:account_id)
    check_for_blocks.concat([status.reblog.account_id]) if status.reblog?

    return true if Block.where(account_id: receiver_id, target_account_id: check_for_blocks).any?

    if status.reply? && !status.in_reply_to_account_id.nil?                                                              # Filter out if it's a reply
      should_filter   = !Follow.where(account_id: receiver_id, target_account_id: status.in_reply_to_account_id).exists? # and I'm not following the person it's a reply to
      should_filter &&= receiver_id != status.in_reply_to_account_id                                                     # and it's not a reply to me
      should_filter &&= status.account_id != status.in_reply_to_account_id                                               # and it's not a self-reply
      return should_filter
    elsif status.reblog?                                                                                                 # Filter out a reblog
      should_filter   = Block.where(account_id: status.reblog.account_id, target_account_id: receiver_id).exists?        # or if the author of the reblogged status is blocking me
      should_filter ||= AccountDomainBlock.where(account_id: receiver_id, domain: status.reblog.account.domain).exists?  # or the author's domain is blocked
      return should_filter
    end

    false
  end

  def filter_from_mentions?(status, receiver_id)
    return true if receiver_id == status.account_id

    check_for_blocks = [status.account_id]
    check_for_blocks.concat(status.mentions.pluck(:account_id))
    check_for_blocks.concat([status.in_reply_to_account]) if status.reply? && !status.in_reply_to_account_id.nil?

    should_filter   = Block.where(account_id: receiver_id, target_account_id: check_for_blocks).any?                                     # Filter if it's from someone I blocked, in reply to someone I blocked, or mentioning someone I blocked
    should_filter ||= (status.account.silenced? && !Follow.where(account_id: receiver_id, target_account_id: status.account_id).exists?) # of if the account is silenced and I'm not following them

    should_filter
  end

  # Adds a status to an account's feed, returning true if a status was
  # added, and false if it was not added to the feed. Note that this is
  # an internal helper: callers must call trim or push updates if
  # either action is appropriate.
  def add_to_feed(timeline_type, account_id, status)
    timeline_key = key(timeline_type, account_id)
    reblog_key   = key(timeline_type, account_id, 'reblogs')

    if status.reblog?
      # If the original status or a reblog of it is within
      # REBLOG_FALLOFF statuses from the top, do not re-insert it into
      # the feed
      rank = redis.zrevrank(timeline_key, status.reblog_of_id)

      return false if !rank.nil? && rank < FeedManager::REBLOG_FALLOFF

      reblog_rank = redis.zrevrank(reblog_key, status.reblog_of_id)

      if reblog_rank.nil?
        # This is not something we've already seen reblogged, so we
        # can just add it to the feed (and note that we're
        # reblogging it).
        redis.zadd(timeline_key, status.id, status.id)
        redis.zadd(reblog_key, status.id, status.reblog_of_id)
      else
        # Another reblog of the same status was already in the
        # REBLOG_FALLOFF most recent statuses, so we note that this
        # is an "extra" reblog, by storing it in reblog_set_key.
        reblog_set_key = key(timeline_type, account_id, "reblogs:#{status.reblog_of_id}")
        redis.sadd(reblog_set_key, status.id)
        return false
      end
    else
      redis.zadd(timeline_key, status.id, status.id)
    end

    true
  end

  # Removes an individual status from a feed, correctly handling cases
  # with reblogs, and returning true if a status was removed. As with
  # `add_to_feed`, this does not trigger push updates, so callers must
  # do so if appropriate.
  def remove_from_feed(timeline_type, account_id, status)
    timeline_key = key(timeline_type, account_id)

    if status.reblog?
      # 1. If the reblogging status is not in the feed, stop.
      status_rank = redis.zrevrank(timeline_key, status.id)
      return false if status_rank.nil?

      # 2. Remove reblog from set of this status's reblogs.
      reblog_set_key = key(timeline_type, account_id, "reblogs:#{status.reblog_of_id}")

      redis.srem(reblog_set_key, status.id)
      # 3. Re-insert another reblog or original into the feed if one
      # remains in the set. We could pick a random element, but this
      # set should generally be small, and it seems ideal to show the
      # oldest potential such reblog.
      other_reblog = redis.smembers(reblog_set_key).map(&:to_i).sort.first

      redis.zadd(timeline_key, other_reblog, other_reblog) if other_reblog

      # 4. Remove the reblogging status from the feed (as normal)
      # (outside conditional)
    else
      # If the original is getting deleted, no use for reblog references
      redis.del(key(timeline_type, account_id, "reblogs:#{status.id}"))
    end

    redis.zrem(timeline_key, status.id)
  end
end
