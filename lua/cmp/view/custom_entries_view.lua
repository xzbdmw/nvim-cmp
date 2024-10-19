local event = require('cmp.utils.event')
local autocmd = require('cmp.utils.autocmd')
local feedkeys = require('cmp.utils.feedkeys')
local window = require('cmp.utils.window')
local config = require('cmp.config')
local types = require('cmp.types')
local keymap = require('cmp.utils.keymap')
local misc = require('cmp.utils.misc')
local api = require('cmp.utils.api')
local DEFAULT_HEIGHT = 10 -- @see https://github.com/vim/vim/blob/master/src/popupmenu.c#L45

---@class cmp.CustomEntriesView
---@field private entries_win cmp.Window
---@field private ghost_text_view cmp.GhostTextView
---@field private offset integer
---@field private active boolean
---@field private entries cmp.Entry[]
---@field private column_width any
---@field public event cmp.Event
local custom_entries_view = {}
custom_entries_view.ns = vim.api.nvim_create_namespace('cmp.view.custom_entries_view')

local cache = {}
_G.query_cache = {}

custom_entries_view.new = function(ghost_text_view)
  local self = setmetatable({}, { __index = custom_entries_view })

  self.entries_win = window.new()
  self.entries_win:option('conceallevel', 2)
  self.entries_win:option('concealcursor', 'n')
  self.entries_win:option('cursorlineopt', 'line')
  self.entries_win:option('foldenable', false)
  self.entries_win:option('wrap', false)
  -- This is done so that strdisplaywidth calculations for lines in the
  -- custom_entries_view window exactly match with what is really displayed,
  -- see comment in cmp.Entry.get_view. Setting tabstop to 1 makes all tabs be
  -- always rendered one column wide, which removes the unpredictability coming
  -- from variable width of the tab character.
  self.entries_win:buffer_option('tabstop', 1)
  self.entries_win:buffer_option('filetype', 'cmp_menu')
  self.entries_win:buffer_option('buftype', 'nofile')
  self.event = event.new()
  self.offset = -1
  self.active = false
  self.entries = {}
  self.bottom_up = false
  self.ghost_text_view = ghost_text_view
  autocmd.subscribe(
    'CompleteChanged',
    vim.schedule_wrap(function()
      if self:visible() and vim.fn.pumvisible() == 1 then
        self:close()
      end
    end)
  )
  vim.api.nvim_set_decoration_provider(custom_entries_view.ns, {
    on_win = function(_, win, buf, top, bot)
      if win ~= self.entries_win.win or buf ~= self.entries_win:get_buffer() then
        return
      end

      local filetype = api.is_cmdline_mode() and 'vim' or vim.bo.filetype
      local query = query_cache[filetype]
      if query == nil then
        query = vim.treesitter.query.get(filetype, 'highlights')
        query_cache[filetype] = query
      end
      local fields = config.get().formatting.fields
      for i = top, bot do
        local e = self.entries[i + 1]
        if e then
          local v = e:get_view(self.offset, buf)
          if filetype == 'vim' then
            v.concat.text = v.abbr.text
          end
          local o = config.get().window.completion.side_padding
          local a = 0
          for _, field in ipairs(fields) do
            if field == types.cmp.ItemField.Abbr then
              a = o
              if cache[v.kind.text .. v.concat.text] then
                for _, node in ipairs(cache[v.kind.text .. v.concat.text]) do
                  pcall(vim.api.nvim_buf_set_extmark, buf, custom_entries_view.ns, i, node.start_col, {
                    end_col = node.end_col,
                    priority = node.priority,
                    hl_group = node.hl,
                    hl_eol = false,
                    ephemeral = true,
                  })
                end
                if #cache > 5000 then
                  cache = {}
                end
              else
                local success, parser = pcall(vim.treesitter.get_string_parser, v.concat.text, filetype)
                if success then
                  local tree = parser:parse(false)[1]
                  local root = tree:root()
                  local offset = v.concat.offset or 0
                  local shift = 0
                  cache[v.kind.text .. v.concat.text] = {}
                  for id, node in query:iter_captures(root, v.concat.text, 0, -1) do
                    local name = '@' .. query.captures[id]
                    local priority = 200
                    if name == '@keyword.import' then
                      goto continue
                    end
                    if name == '@string' then
                      priority = 1000
                    end
                    if name == '@comment' then
                      shift = 2
                    end
                    local next = true
                    if name ~= '@spell' and shift == 2 then
                      next = false
                    end
                    if name == '@spell' and next then
                      next = false
                      goto continue
                    end
                    name = name .. '.' .. filetype
                    local hl = vim.api.nvim_get_hl_id_by_name(name)
                    local range = { node:range() }
                    local _, nscol, _, necol = range[1], range[2], range[3], range[4]
                    pcall(vim.api.nvim_buf_set_extmark, buf, custom_entries_view.ns, i, nscol + o - offset - shift, {
                      end_col = necol + o - offset - shift,
                      priority = priority,
                      hl_group = hl,
                      hl_eol = false,
                      ephemeral = true,
                    })
                    table.insert(cache[v.kind.text .. v.concat.text], { name = name, start_col = nscol + o - offset - shift, end_col = necol + o - offset - shift, priority = priority, hl = hl })
                    ::continue::
                  end
                else
                  vim.api.nvim_buf_set_extmark(buf, custom_entries_view.ns, i, o, {
                    end_line = i,
                    end_col = o + v[field].bytes,
                    hl_group = v[field].hl_group,
                    hl_mode = 'combine',
                    ephemeral = true,
                  })
                end
              end
            else
              vim.api.nvim_buf_set_extmark(buf, custom_entries_view.ns, i, o, {
                end_line = i,
                end_col = o + v[field].bytes,
                hl_group = v[field].hl_group,
                hl_mode = 'combine',
                ephemeral = true,
              })
            end

            o = o + v[field].bytes + (self.column_width[field] - v[field].width) + 1
          end

          for _, m in ipairs(e:get_view_matches(v.abbr.text) or {}) do
            vim.api.nvim_buf_set_extmark(buf, custom_entries_view.ns, i, a + m.word_match_start - 1, {
              end_line = i,
              end_col = a + m.word_match_end,
              hl_group = m.fuzzy and 'CmpItemAbbrMatchFuzzy' or 'CmpItemAbbrMatch',
              hl_mode = 'combine',
              ephemeral = true,
            })
          end
        end
      end
    end,
  })

  return self
end

custom_entries_view.ready = function()
  return vim.fn.pumvisible() == 0
end

custom_entries_view.on_change = function(self)
  self.active = false
end

custom_entries_view.is_direction_top_down = function(self)
  local c = config.get()
  if (c.view and c.view.entries and c.view.entries.selection_order) == 'top_down' then
    return true
  elseif c.view.entries == nil or c.view.entries.selection_order == nil then
    return true
  else
    return not self.bottom_up
  end
end

custom_entries_view.open = function(self, offset, entries)
  local completion = config.get().window.completion
  assert(completion, 'config.get() must resolve window.completion with defaults')

  self.offset = offset
  self.entries = {}
  self.column_width = { abbr = 0, kind = 0, menu = 0 }

  local entries_buf = self.entries_win:get_buffer()
  local lines = {}
  local dedup = {}
  local preselect_index = 0
  for _, e in ipairs(entries) do
    local view = e:get_view(offset, entries_buf)
    if view.dup == 1 or not dedup[e.completion_item.label] then
      dedup[e.completion_item.label] = true
      self.column_width.abbr = math.max(self.column_width.abbr, view.abbr.width)
      self.column_width.kind = math.max(self.column_width.kind, view.kind.width)
      self.column_width.menu = math.max(self.column_width.menu, view.menu.width)
      table.insert(self.entries, e)
      table.insert(lines, ' ')
      if preselect_index == 0 and e.completion_item.preselect then
        preselect_index = #self.entries
      end
    end
  end
  self.column_width.abbr = self.column_width.abbr - 1
  if vim.bo[entries_buf].modifiable == false then
    vim.bo[entries_buf].modifiable = true
    vim.api.nvim_buf_set_lines(entries_buf, 0, -1, false, lines)
    vim.bo[entries_buf].modifiable = false
  else
    vim.api.nvim_buf_set_lines(entries_buf, 0, -1, false, lines)
  end
  vim.api.nvim_buf_set_option(entries_buf, 'modified', false)

  local width = 0
  width = width + 1
  width = width + self.column_width.abbr + (self.column_width.kind > 0 and 1 or 0)
  width = width + self.column_width.kind + (self.column_width.menu > 0 and 1 or 0)
  width = width + self.column_width.menu + 1

  local height = vim.api.nvim_get_option('pumheight')
  height = height ~= 0 and height or #self.entries
  height = math.min(height, #self.entries)

  local pos = api.get_screen_cursor()
  local cursor_before_line = api.get_cursor_before_line()
  local delta = vim.fn.strdisplaywidth(cursor_before_line:sub(self.offset))
  local row, col = pos[1], pos[2] - delta - 1

  local border_info = window.get_border_info({ style = completion })
  local border_offset_row = border_info.top + border_info.bottom
  local border_offset_col = border_info.left + border_info.right
  if math.floor(vim.o.lines * 0.5) <= row + border_offset_row and vim.o.lines - row - border_offset_row <= math.min(DEFAULT_HEIGHT, height) then
    height = math.min(height, row - 1)
    row = row - height - border_offset_row - 1
    if row < 0 then
      height = height + row
    end
  end
  if math.floor(vim.o.columns * 0.5) <= col + border_offset_col and vim.o.columns - col - border_offset_col <= width then
    width = math.min(width, vim.o.columns - 1)
    -- col = vim.o.columns - width - border_offset_col - 1
    -- if col < 0 then
    --   width = width + col
    -- end
  end

  if pos[1] > row then
    self.bottom_up = true
  else
    self.bottom_up = false
  end

  if not self:is_direction_top_down() then
    local n = #self.entries
    for i = 1, math.floor(n / 2) do
      self.entries[i], self.entries[n - i + 1] = self.entries[n - i + 1], self.entries[i]
    end
    if preselect_index ~= 0 then
      preselect_index = #self.entries - preselect_index + 1
    end
  end

  -- Apply window options (that might be changed) on the custom completion menu.
  self.entries_win:option('winblend', vim.o.pumblend)
  self.entries_win:option('winhighlight', completion.winhighlight)
  self.entries_win:option('scrolloff', 2)
  self.entries_win:open({
    relative = 'editor',
    style = 'minimal',
    row = math.max(0, row),
    col = math.max(0, col + completion.col_offset),
    width = width,
    height = height,
    border = completion.border,
    zindex = completion.zindex or 1001,
  })

  -- Don't set the cursor if the entries_win:open function fails
  -- due to the window's width or height being less than 1
  if self.entries_win.win == nil then
    return
  end

  -- Always set cursor when starting. It will be adjusted on the call to _select
  vim.api.nvim_win_set_cursor(self.entries_win.win, { 1, 0 })
  if preselect_index > 0 and config.get().preselect == types.cmp.PreselectMode.Item then
    self:_select(preselect_index, { behavior = types.cmp.SelectBehavior.Select, active = false })
  elseif not string.match(config.get().completion.completeopt, 'noselect') then
    if self:is_direction_top_down() then
      self:_select(1, { behavior = types.cmp.SelectBehavior.Select, active = false })
    else
      self:_select(#self.entries, { behavior = types.cmp.SelectBehavior.Select, active = false })
    end
  else
    if self:is_direction_top_down() then
      self:_select(0, { behavior = types.cmp.SelectBehavior.Select, active = false })
    else
      self:_select(#self.entries + 1, { behavior = types.cmp.SelectBehavior.Select, active = false })
    end
  end
end

custom_entries_view.close = function(self)
  self.prefix = nil
  self.offset = -1
  self.active = false
  self.entries = {}
  self.entries_win:close()
  self.bottom_up = false
end

custom_entries_view.abort = function(self)
  if self.prefix then
    self:_insert(self.prefix)
  end
  feedkeys.call('', 'n', function()
    self:close()
  end)
end

custom_entries_view.draw = function(self)
  local info = vim.fn.getwininfo(self.entries_win.win)[1]
  local topline = info.topline - 1
  local botline = info.topline + info.height - 1
  local texts = {}
  local fields = config.get().formatting.fields
  local entries_buf = self.entries_win:get_buffer()
  for i = topline, botline - 1 do
    local e = self.entries[i + 1]
    if e then
      local view = e:get_view(self.offset, entries_buf)
      local text = {}
      table.insert(text, string.rep(' ', config.get().window.completion.side_padding))
      for _, field in ipairs(fields) do
        table.insert(text, view[field].text)
        table.insert(text, string.rep(' ', 1 + self.column_width[field] - view[field].width))
      end
      table.insert(text, string.rep(' ', config.get().window.completion.side_padding))
      table.insert(texts, table.concat(text, ''))
    end
  end
  if vim.bo[entries_buf].modifiable == false then
    vim.bo[entries_buf].modifiable = true
    vim.api.nvim_buf_set_lines(entries_buf, topline, botline, false, texts)
    vim.bo[entries_buf].modifiable = false
  else
    vim.api.nvim_buf_set_lines(entries_buf, topline, botline, false, texts)
  end
  vim.api.nvim_buf_set_option(entries_buf, 'modified', false)

  if api.is_cmdline_mode() then
    vim.api.nvim_win_call(self.entries_win.win, function()
      misc.redraw()
    end)
  end
end

custom_entries_view.visible = function(self)
  return self.entries_win:visible()
end

custom_entries_view.info = function(self)
  return self.entries_win:info()
end

custom_entries_view.select_cur_item = function(self, option)
  if self:visible() then
    local cursor = vim.api.nvim_win_get_cursor(self.entries_win.win)[1]
    self:_select(cursor, {
      behavior = option.behavior or types.cmp.SelectBehavior.Insert,
      active = true,
    })
  end
end

custom_entries_view.select_next_item = function(self, option)
  if self:visible() then
    local cursor = vim.api.nvim_win_get_cursor(self.entries_win.win)[1]
    local is_top_down = self:is_direction_top_down()
    local last = #self.entries
    if not self.entries_win:option('cursorline') then
      cursor = (is_top_down and 1) or last
    else
      if is_top_down then
        if cursor == last then
          cursor = 1
        else
          cursor = cursor + option.count
          if last < cursor then
            cursor = last
          end
        end
      else
        if cursor == 1 then
          cursor = last
        else
          cursor = cursor - option.count
          if cursor < 1 then
            cursor = 1
          end
        end
      end
    end
    self:_select(cursor, {
      behavior = option.behavior or types.cmp.SelectBehavior.Insert,
      active = true,
    })
  end
end

custom_entries_view.select_prev_item = function(self, option)
  if self:visible() then
    local cursor = vim.api.nvim_win_get_cursor(self.entries_win.win)[1]
    local is_top_down = self:is_direction_top_down()
    local last = #self.entries
    if not self.entries_win:option('cursorline') then
      cursor = (is_top_down and last) or 1
    else
      if is_top_down then
        if cursor == 1 then
          cursor = last
        else
          cursor = cursor - option.count
          if cursor < 0 then
            cursor = 1
          end
        end
      else
        if cursor == last then
          cursor = 1
        else
          cursor = cursor + option.count
          if last < cursor then
            cursor = last
          end
        end
      end
    end
    self:_select(cursor, {
      behavior = option.behavior or types.cmp.SelectBehavior.Insert,
      active = true,
    })
  end
end

custom_entries_view.get_offset = function(self)
  if self:visible() then
    return self.offset
  end
  return nil
end

custom_entries_view.get_entries = function(self)
  if self:visible() then
    return self.entries
  end
  return {}
end

custom_entries_view.get_first_entry = function(self)
  if self:visible() then
    return (self:is_direction_top_down() and self.entries[1]) or self.entries[#self.entries]
  end
end

custom_entries_view.get_selected_entry = function(self)
  if self:visible() and self.entries_win:option('cursorline') then
    return self.entries[vim.api.nvim_win_get_cursor(self.entries_win.win)[1]]
  end
end

custom_entries_view.get_active_entry = function(self)
  if self:visible() and self.active then
    return self:get_selected_entry()
  end
end

custom_entries_view._select = function(self, cursor, option)
  local is_insert = (option.behavior or types.cmp.SelectBehavior.Insert) == types.cmp.SelectBehavior.Insert
  if is_insert and not self.active then
    self.prefix = string.sub(api.get_current_line(), self.offset, api.get_cursor()[2]) or ''
  end
  self.active = (0 < cursor and cursor <= #self.entries and option.active == true)

  self.entries_win:option('cursorline', cursor > 0 and cursor <= #self.entries)
  vim.api.nvim_win_set_cursor(self.entries_win.win, {
    math.max(math.min(cursor, #self.entries), 1),
    0,
  })

  if not self.bottom_up then
    local info = self.entries_win:info()
    local border_info = info.border_info
    local border_offset_row = border_info.top + border_info.bottom
    local row = api.get_screen_cursor()[1]

    -- If user specify 'noselect', select first entry
    local entry = self:get_selected_entry() or self:get_first_entry()
    local should_move_up = self.ghost_text_view:has_multi_line(entry) and row > self.entries_win:get_content_height() + border_offset_row

    if should_move_up then
      self.bottom_up = true

      -- This logic keeps the same as open()
      local height = vim.api.nvim_get_option_value('pumheight', {})
      height = height ~= 0 and height or #self.entries
      height = math.min(height, #self.entries)
      height = math.min(height, row - 1)

      row = row - height - border_offset_row - 1
      if row < 0 then
        height = height + row
      end

      local completion = config.get().window.completion
      local new_position = {
        style = 'minimal',
        relative = 'editor',
        row = math.max(0, row),
        height = height,
        col = info.col,
        width = info.width,
        border = completion.border,
        zindex = completion.zindex or 1001,
      }
      self.entries_win:open(new_position)

      if not self:is_direction_top_down() then
        local n = #self.entries
        for i = 1, math.floor(n / 2) do
          self.entries[i], self.entries[n - i + 1] = self.entries[n - i + 1], self.entries[i]
        end
        self:_select(#self.entries - cursor + 1, option)
      else
        self:_select(cursor, option)
      end
    end
  end

  if is_insert then
    self:_insert(self.entries[cursor] and self.entries[cursor]:get_vim_item(self.offset).word or self.prefix)
  end

  self.entries_win:update()
  self:draw()
  self.event:emit('change')
end

custom_entries_view._insert = setmetatable({
  pending = false,
}, {
  __call = function(this, self, word)
    word = word or ''
    if api.is_cmdline_mode() then
      local cursor = api.get_cursor()
      -- setcmdline() added in v0.8.0
      if vim.fn.has('nvim-0.8') == 1 then
        local current_line = api.get_current_line()
        local before_line = current_line:sub(1, self.offset - 1)
        local after_line = current_line:sub(cursor[2] + 1)
        local pos = #before_line + #word + 1
        vim.fn.setcmdline(before_line .. word .. after_line, pos)
        vim.api.nvim_feedkeys(keymap.t('<Cmd>redraw<CR>'), 'ni', false)
      else
        vim.api.nvim_feedkeys(keymap.backspace(string.sub(api.get_current_line(), self.offset, cursor[2])) .. word, 'int', true)
      end
    else
      if this.pending then
        return
      end
      this.pending = true

      local release = require('cmp').suspend()
      feedkeys.call('', '', function()
        local cursor = api.get_cursor()
        local keys = {}
        table.insert(keys, keymap.indentkeys())
        table.insert(keys, keymap.backspace(string.sub(api.get_current_line(), self.offset, cursor[2])))
        table.insert(keys, word)
        table.insert(keys, keymap.indentkeys(vim.bo.indentkeys))
        feedkeys.call(
          table.concat(keys, ''),
          'int',
          vim.schedule_wrap(function()
            this.pending = false
            release()
          end)
        )
      end)
    end
  end,
})

return custom_entries_view
