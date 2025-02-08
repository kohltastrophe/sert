<h1 align="center">Simple and Expressive Roblox Testing</h1>
<p align="center">Sert is a lightweight, easy-to-use testing framework for Roblox, designed for simplicity and clarity.</p>

## ✨ Key Features

- **Simple API:** Write tests with minimal boilerplate.
- **Asynchronous Support:** Run tests concurrently; Promises are supported for asynchronous assertions.
- **Lifecycle Hooks:** `beforeEach`, `afterEach`, and `after` hooks for setup and teardown.
- **Focused and Skipped Tests:** Run only specific tests or skip others during development.
- **Informative Output:** Clear, concise test results in the output.
- **Global Variable Injection:** Mock services and control the test environment.
- **Flexible Configuration:** Control asynchronous behavior globally or per-test module.
- **No External Dependencies:** Sert is a single module – easy to install and manage.

## ⏱️ Getting Started

### Installation

#### 1. Copy the provided `src/init.luau` code into a new module named `Sert`.

#### 2. Create a new Script (or LocalScript) and add:

```lua
local Sert = require "../Sert" -- Adjust path if needed
local results = Sert.run("../Tests") -- Or the path containing your tests
```

### Writing tests

#### 1. **Create a module to test:** `Greeter`

```lua
local Greeter = {}

function Greeter:greet(person)
	return "Hello, " .. person
end

return Greeter
```

#### 2. **Create a test module:** `Greeter.test`

```lua
local Greeter = require "../Greeter"

return {
	-- Optional: Configure test behaviour
	_async = nil, -- true = force async, false = force sync, nil = use global setting
	_focus = nil, -- true = hides tests that are not focused
	_skip = nil, -- true = skips this test

	-- Optional: Lifecycle hooks
	after = function()
		-- Cleanup after all tests
	end,
	afterEach = function()
		-- Runs after each test
	end,
	beforeEach = function()
		-- Runs before each test
	end,

	-- Test cases
	["should include greeting"] = function()
		local greeting = Greeter:greet("X")
		assert(greeting:match("Hello"), "expected string to contain 'Hello', got " .. greeting)
	end,
	["should include name"] = function()
		local greeting = Greeter:greet("Joe")
		assert(greeting:match("Joe"), "expected string to contain 'Joe', got " .. greeting)
	end,
	["should fail"] = function()
		error("Example error")
	end,
	["should skip"] = function()
		return "SKIP"
	end,
}
```

#### Promises

Return a [promise](https://github.com/evaera/roblox-lua-promise) in your test and Sert will wait for it to resolve. If the promise is rejected, the test will fail.

For example, let's consider a promise with a fetchData function. We could test it with:

```lua
["the data is hello world"] = function()
	return Promise.resolve()
		:andThen(function()
			local data = fetchData()
			assert(data == "Hello world!", "expected 'Hello world!', got" .. greeting)
		end)
end,
```

### Test Output

Sert provides detailed output including:

- Test status (✅ pass, ❌ fail, or 🟡 skip)
- Test execution time
- Error messages for failed tests
- Summary of total passed/failed/skipped tests

Example output:

```
Test Results:
Tests
  Greeter.test  3 ms
    ✅ should include greeting  2 ms
    ✅ should include name      1 ms
    ❌ should fail              0 ms
      ⚠️ Example error
    🟡 should skip              0 ms

⚠️ Some tests failed! Check output for details. | 2 passed | 1 failed | 1 skipped
```

## ⚙️ Configuration

### Async Behavior

Tests run asynchronously by default. You can control this behavior:

- **Globally:** In `Sert.run` set the `async` parameter to `false` to run tests synchronously by default
- **Per Test:** Set `_async` in your test module return table:
  - `_async = true`: Force async execution for this module
  - `_async = false`: Force sync execution for this module
  - `_async = nil`: Use global setting

### Focus Behaviour

Tests can be focused for debugging, **hiding other unfocused tests**:

- **Per Test:** Set `_focus` to `true` in your test module return table

### Skip Behaviour

Tests can be skipped for debugging:

- **Per Test Case:** Return `"SKIP"` in your test case
- **Per Test:** Set `_skip` to `true` in your test module return table

### Sert.run Parameters

The `Sert.run` function accepts four parameters:

```lua
Sert.run(object: Instance | Set, globals: Set?, async: boolean?, silent: boolean?)
```

1. `object`: The `Instance` or `table` to test or search for test modules in (required)
2. `globals`: A `table` of global variables to inject into test functions (optional)
3. `async`: If `false`, runs tests synchronously, defaults to `true` (optional)
4. `silent`: If `true`, suppresses console output and only returns results (optional)

#### Using globals

The `globals` parameter allows you to inject global variables into your test functions. This can be useful for mocking global services or providing test-specific utilities:

```lua
local Sert = require(script.Parent.Sert)

local mockGlobals = {
	game = {}, -- Mock game service
	warn = function() end, -- Silent warning function
	-- Add other global variables/functions
}

Sert.run(script.Parent.Tests, mockGlobals)
```

> [!WARNING]
> Using `globals` can impact performance as it disables some Luau optimizations. Use it only when necessary.

## 📁 File Organization

### Recommended Structure

```
MyProject
├─┬ TestRunner
│ └── Sert
├─┬ Modules
│ ├── Greeter
│ └── Greeter.test
└─┬ Tests
  └─┬ Features
    ├── Login.test
    └── Profile.test
```

- Tests can be placed alongside modules or organized in a dedicated test directory
- Test modules must end with `.test`

## ✍️ Best Practices

- Use descriptive test names that explain the expected behavior
- Make specific assertions that test one behavior at a time
- Keep test modules close to the code they're testing
- Focus and skip tests to speed up the debug process
- Use lifecycle hooks to ensure proper cleanup between tests
- Consider disabling async for tests that may have race conditions

## 📄 License

This project is licensed under the [MIT License](LICENSE.txt).
