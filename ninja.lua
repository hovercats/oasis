--
-- utility functions
--

function string.hasprefix(s, prefix)
	return s:sub(1, #prefix) == prefix
end

function string.hassuffix(s, suffix)
	return s:sub(-#suffix) == suffix
end

-- collects the results of an iterator into a table
local function collect(fn, s, i)
	local results, nresults = {}, 0
	for val in fn, s, i do
		nresults = nresults + 1
		results[nresults] = val
	end
	return results
end

-- collects the keys of a table into a sorted table
function table.keys(t)
	local keys = collect(next, t)
	table.sort(keys)
	return keys
end

-- yields string values of table or nested tables
local function stringsgen(t)
	for _, val in ipairs(t) do
		if type(val) == 'string' then
			coroutine.yield(val)
		else
			stringsgen(val)
		end
	end
end

function iterstrings(x)
	return coroutine.wrap(stringsgen), x
end

function strings(s)
	return collect(iterstrings(s))
end

-- yields strings generated by concateting all strings in a table, for every
-- combination of strings in subtables
local function expandgen(t, i)
	while true do
		local val
		i, val = next(t, i)
		if not i then
			coroutine.yield(table.concat(t))
			break
		elseif type(val) == 'table' then
			for opt in iterstrings(val) do
				t[i] = opt
				expandgen(t, i)
			end
			t[i] = val
			break
		end
	end
end

function expand(t)
	return collect(coroutine.wrap(expandgen), t)
end

-- yields expanded paths from the given path specification string
function pathsgen(s, i)
	local results = {}
	local first = not i
	while true do
		i = s:find('%g', i)
		if not i or s:sub(i, i) == ')' then
			break
		end
		local parts, nparts = {}, 0
		local c
		while true do
			local j = s:find('[%s()]', i)
			if not j or j > i then
				nparts = nparts + 1
				parts[nparts] = s:sub(i, j and j - 1)
			end
			i = j
			c = i and s:sub(i, i)
			if c == '(' then
				local opts, nopts = {}, 0
				local fn = coroutine.wrap(pathsgen)
				local opt
				opt, i = fn(s, i + 1)
				while opt do
					nopts = nopts + 1
					opts[nopts] = opt
					opt, i = fn(s)
				end
				nparts = nparts + 1
				parts[nparts] = opts
				if not i or s:sub(i, i) ~= ')' then
					error('unmatched (')
				end
				i = i + 1
				c = s:sub(i, i)
			else
				break
			end
		end
		expandgen(parts)
		if not c or c == ')' then
			break
		end
	end
	if first and i then
		error('unmatched )')
	end
	return nil, i
end

function iterpaths(s)
	return coroutine.wrap(pathsgen), s
end

function paths(s)
	return collect(iterpaths(s))
end

-- yields non-empty non-comment lines in a file
function linesgen(file)
	table.insert(pkg.inputs.gen, '$dir/'..file)
	for line in io.lines(pkg.dir..'/'..file) do
		if #line > 0 and not line:hasprefix('#') then
			coroutine.yield(line)
		end
	end
end

function iterlines(file)
	return coroutine.wrap(linesgen), file
end

function lines(file)
	return collect(iterlines(file))
end

--
-- base constructs
--

function set(var, val, indent)
	if type(val) == 'table' then
		val = table.concat(val, ' ')
	end
	io.write(string.format('%s%s = %s\n', indent or '', var, val))
end

function subninja(file)
	if not file:hasprefix('$') then
		file = '$dir/'..file
	end
	io.write(string.format('subninja %s\n', file))
end

function include(file)
	io.write(string.format('include %s\n', file))
end

local function let(bindings)
	for var, val in pairs(bindings) do
		set(var, val, '  ')
	end
end

function rule(name, cmd, bindings)
	io.write(string.format('rule %s\n  command = %s\n', name, cmd))
	if bindings then
		let(bindings)
	end
end

function build(rule, outputs, inputs, bindings)
	if type(outputs) == 'table' then
		outputs = table.concat(strings(outputs), ' ')
	end
	if not inputs then
		inputs = ''
	elseif type(inputs) == 'table' then
		local srcs, nsrcs = {}, 0
		for src in iterstrings(inputs) do
			nsrcs = nsrcs + 1
			srcs[nsrcs] = src
			if src:hasprefix('$srcdir/') then
				pkg.inputs.fetch[src] = true
			end
		end
		inputs = table.concat(srcs, ' ')
	elseif inputs:hasprefix('$srcdir/') then
		pkg.inputs.fetch[inputs] = true
	end
	io.write(string.format('build %s: %s %s\n', outputs, rule, inputs))
	if bindings then
		let(bindings)
	end
end

--
-- higher-level rules
--

function sub(name, fn)
	local old = io.output()
	io.output(pkg.dir..'/'..name)
	fn()
	io.output(old)
	subninja(name)
end

function toolchain(name)
	set('cflags', '$'..name..'_cflags')
	set('cxxflags', '$'..name..'_cxxflags')
	set('ldflags', '$'..name..'_ldflags')
	include('toolchain/$'..name..'_toolchain.ninja')
end

function phony(name, inputs)
	build('phony', '$dir/'..name, inputs)
end

function cflags(flags)
	set('cflags', '$cflags '..table.concat(flags, ' '))
end

function compile(rule, src, deps, args)
	local obj = src..'.o'
	if not src:hasprefix('$') then
		src = '$srcdir/'..src
		obj = '$outdir/'..obj
	end
	if not deps and pkg.deps then
		deps = '$dir/deps'
	end
	if deps then
		src = {src, '||', deps}
	end
	build(rule, obj, src, args)
	return obj
end

function cc(src, deps, args)
	return compile('cc', src, deps, args)
end

function objects(srcs, deps)
	local objs, nobjs = {}, 0
	local rules = {
		c='cc',
		s='cc',
		S='cc',
		cc='cc',
		cpp='cc',
		asm='nasm',
	}
	local fn
	if type(srcs) == 'string' then
		fn = coroutine.wrap(pathsgen)
	else
		fn = coroutine.wrap(stringsgen)
	end
	for src in fn, srcs do
		local rule = rules[src:match('[^.]*$')]
		if rule then
			src = compile(rule, src, deps)
		end
		nobjs = nobjs + 1
		objs[nobjs] = src
	end
	return objs
end

function link(out, files, args)
	local objs, nobjs = {}, 0
	local deps, ndeps = {}, 0
	for _, file in ipairs(files) do
		if not file:hasprefix('$') then
			file = '$outdir/'..file
		end
		if file:hassuffix('.d') then
			ndeps = ndeps + 1
			deps[ndeps] = file
		else
			nobjs = nobjs + 1
			objs[nobjs] = file
		end
	end
	out = '$outdir/'..out
	if not args then
		args = {}
	end
	if next(deps) then
		local rsp = out..'.rsp'
		build('awk', rsp, {deps, '|', 'scripts/rsp.awk'}, {expr='-f scripts/rsp.awk'})
		objs = {objs, '|', rsp}
		args.ldlibs = '@'..rsp
	end
	build('link', out, objs, args)
	return out
end

function ar(out, files)
	out = '$outdir/'..out
	local objs, nobjs = {}, 0
	local deps, ndeps = {out}, 1
	for _, file in ipairs(files) do
		if not file:hasprefix('$') then
			file = '$outdir/'..file
		end
		if file:find('%.[ad]$') then
			ndeps = ndeps + 1
			deps[ndeps] = file
		else
			nobjs = nobjs + 1
			objs[nobjs] = file
		end
	end
	build('ar', out, objs)
	build('lines', out..'.d', deps)
end

function lib(out, srcs, deps)
	return ar(out, objects(srcs, deps))
end

function exe(out, srcs, deps, args)
	return link(out, objects(srcs, deps), args)
end

function yacc(name, gram)
	if not gram:hasprefix('$') then
		gram = '$srcdir/'..gram
	end
	build('yacc', expand{'$outdir/', name, {'.tab.c', '.tab.h'}}, gram, {
		yaccflags='-d -b '..name,
	})
end

function waylandproto(proto, client, server, code)
	proto = '$srcdir/'..proto
	code = '$outdir/'..code
	build('waylandproto', '$outdir/'..client, proto, {type='client-header'})
	build('waylandproto', '$outdir/'..server, proto, {type='server-header'})
	build('waylandproto', code, proto, {type='code'})
	cc(code, {'pkg/wayland/headers'})
end

function fetch(method, args)
	build('fetch'..method, '$outdir/fetch.stamp', {'|', '$dir/rev'}, {args=args})
	if next(pkg.inputs.fetch) then
		build('phony', table.keys(pkg.inputs.fetch), '$outdir/fetch.stamp')
	end
end

local function findany(path, pats)
	for _, pat in pairs(pats) do
		if path:find(pat) then
			return true
		end
	end
	return false
end

local function specmatch(spec, path)
	if spec.include and not findany(path, spec.include) then
		return false
	end
	if spec.exclude and findany(path, spec.exclude) then
		return false
	end
	return true
end

local function fs(name, path)
	for _, spec in ipairs(config.fs) do
		for specname in iterstrings(spec) do
			if name == specname then
				return specmatch(spec, path)
			end
		end
	end
	return (config.fs.include or config.fs.exclude) and specmatch(config.fs, path)
end

function file(path, mode, src)
	if pkg.dir:hasprefix('pkg/') and not fs(pkg.name, path) then
		return
	end
	local out = '$builddir/root.hash/'..path
	mode = tonumber(mode, 8)
	local perm = string.format('10%04o %s', mode, path)
	build('githash', out, {src, '|', 'scripts/hash.rc', '||', '$builddir/root.stamp'}, {
		args=perm,
	})
	table.insert(pkg.inputs.index, out)
	if mode ~= 420 and mode ~= 493 then -- 0644 and 0755
		table.insert(pkg.perms, perm)
	end
end

function dir(path, mode)
	if pkg.dir:hasprefix('pkg/') and not fs(pkg.name, path) then
		return
	end
	mode = tonumber(mode, 8)
	table.insert(pkg.perms, string.format('04%04o %s', mode, path))
end

function sym(path, target)
	if pkg.dir:hasprefix('pkg/') and not fs(pkg.name, path) then
		return
	end
	local out = '$builddir/root.hash/'..path
	build('githash', out, {'|', 'scripts/hash.rc', '||', '$builddir/root.stamp'}, {
		args=string.format('120000 %s %s', path, target),
	})
	table.insert(pkg.inputs.index, out)
end

function man(srcs, section)
	for _, src in ipairs(srcs) do
		if not src:hasprefix('$') then
			src = '$srcdir/'..src
		end
		local i = src:find('/', 1, true)
		local gz = '$outdir'..src:sub(i)..'.gz'
		build('gzip', gz, src)
		local srcsection = section or src:match('[^.]*$')
		file('share/man/man'..srcsection..'/'..gz:match('[^/]*$'), '644', gz)
	end
end

function copy(outdir, srcdir, files)
	local outs = {}
	for i, file in ipairs(files) do
		local out = outdir..'/'..file
		outs[i] = out
		build('copy', out, srcdir..'/'..file)
	end
	return outs
end
