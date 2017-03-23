local crud = require "kong.api.crud_helpers"
local app_helpers = require "lapis.application"
local responses = require "kong.tools.responses"
local balancer = require "kong.core.balancer"

return {
  ["/upstreams/"] = {
    GET = function(self, dao_factory)
      crud.paginated_set(self, dao_factory.upstreams)
    end,

    PUT = function(self, dao_factory)
      crud.put(self.params, dao_factory.upstreams)
    end,

    POST = function(self, dao_factory, helpers)
      crud.post(self.params, dao_factory.upstreams)
    end
  },

  ["/upstreams/:name_or_id"] = {
    before = function(self, dao_factory, helpers)
      crud.find_upstream_by_name_or_id(self, dao_factory, helpers)
    end,

    GET = function(self, dao_factory, helpers)
      return helpers.responses.send_HTTP_OK(self.upstream)
    end,

    PATCH = function(self, dao_factory)
      crud.patch(self.params, dao_factory.upstreams, self.upstream)
    end,

    DELETE = function(self, dao_factory)
      crud.delete(self.upstream, dao_factory.upstreams)
    end
  },

  ["/upstreams/:name_or_id/targets/"] = {
    before = function(self, dao_factory, helpers)
      crud.find_upstream_by_name_or_id(self, dao_factory, helpers)
      self.params.upstream_id = self.upstream.id
    end,

    GET = function(self, dao_factory)
      crud.paginated_set(self, dao_factory.targets)
    end,

    POST = function(self, dao_factory, helpers)
      balancer.clean_history(self.params.upstream_id, dao_factory)

      crud.post(self.params, dao_factory.targets)
    end,
  },

  ["/upstreams/:name_or_id/targets/active/"] = {
    before = function(self, dao_factory, helpers)
      crud.find_upstream_by_name_or_id(self, dao_factory, helpers)
      self.params.upstream_id = self.upstream.id
    end,

    GET = function(self, dao_factory)
      self.params.active = nil

      local target_history, err = dao_factory.targets:find_all({
        upstream_id = self.params.upstream_id,
      })

      if not target_history then
        return app_helpers.yield_error(err)
      end

      --sort and walk based on target and creation time
      for _, target in ipairs(target_history) do
        target.order = target.target..":"..target.created_at..":"..target.id
      end
      table.sort(target_history, function(a, b) return a.order > b.order end)

      local ignored = {}
      local found = {}
      local found_n = 0

      for _, entry in ipairs(target_history) do
        if not found[entry.target] and not ignored[entry.target] then
          if entry.weight ~= 0 then
            entry.order = nil -- dont show our order key to the client
            found_n = found_n + 1
            found[found_n] = entry
          else
            ignored[entry.target] = true
          end
        end
      end

      -- for now lets not worry about rolling our own pagination
      -- we also end up returning a "backwards" list of targets because
      -- of how we sorted- do we care?
      return responses.send_HTTP_OK {
        total = found_n,
        data  = found,
      }
    end
  },

  ["/upstreams/:name_or_id/targets/:target"] = {
    before = function(self, dao_factory, helpers)
      crud.find_upstream_by_name_or_id(self, dao_factory, helpers)
      self.params.upstream_id = self.upstream.id
    end,

    DELETE = function(self, dao_factory)
      balancer.clean_history(self.params.upstream_id, dao_factory)

      -- this is just a wrapper around POSTing a new target with weight=0
      local target  = self.params
      target.weight = 0

      local data, err = dao_factory.targets:insert(target)
      if err then
        return app_helpers.yield_error(err)
      end

      return responses.send_HTTP_NO_CONTENT()
    end
  }
}
