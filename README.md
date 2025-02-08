# Sert

Sert provides a straightforward way to write and run unit tests for your Roblox scripts. It's designed to be easy to pick up and integrate into your workflow, while offering essential features for verifying the behavior of your code.

## Features

* **Simple Setup:** Easy to integrate, just copy the `src/init.luau` module into your project.
* **Test Organization:** Organize your tests in `.test` modules alongside your code.
* **Clear Test Structure:** Define tests with descriptive labels and test functions.
* **Easy Debugging:** Focus or skip tests to refine your results.
* **Concise Output:** Get clear and informative test results with timing information.
* **Async Support:** Run tests asynchronously by default with configurable behavior and [promise](https://github.com/evaera/roblox-lua-promise) support.
* **Lifecycle Hooks:** Utilize `beforeEach`, `afterEach`, and `after` functions for setup and teardown actions.

## Getting Started

### Installation

1. Copy the provided `src/init.luau` module code into a new ModuleScript named `Sert` in your Roblox project.
2. Create a new Script (or LocalScript) and add:

```lua
local Sert = require(script.Parent.Sert) -- Adjust path if needed
Sert.run(script.Parent.Tests) -- Or the Instance containing your tests
```

### Writing tests

1. **Create a Module to Test:**  `Greeter`

```lua
local Greeter = {}

function Greeter:greet(person)
	return "Hello, " .. person
end

return Greeter
```

2. **Create a Test Module:** `Greeter.test`

```lua
local Greeter = require(script.Parent.Greeter)

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
		assert(greeting:match("Hello"))
	end,
	["should include name"] = function()
		local greeting = Greeter:greet("Joe")
		assert(greeting:match("Joe"))
	end,
	["should fail"] = function()
		error("Example error")
	end,
}
```

#### Promises

Return a [promise](https://github.com/evaera/roblox-lua-promise) in your test and Sert will wait for it to resolve. If the promise is rejected, the test will fail.

For example, fetchData returns a promise that resolves to a string. We could test it with:

> [!Important]
> Tests can **ONLY** return either a Promise or nil.

```lua
["the data is hello world"] = function()
	return Promise.resolve()
		:andThen(function()
			local data = fetchData()
			assert(data == "Hello world!")
		end)
end,
```

### Test Output

Sert provides detailed output including:
* Test status (✅ pass or ❌ fail)
* Test execution time
* Error messages for failed tests
* Summary of total passed/failed tests

Example output:
```
Test Results:
Tests
  Greeter.test  4 ms
    ✅ should include greeting  2 ms
    ✅ should include name      1 ms
    ❌ should fail              1 ms
      ⚠️ Example error

⚠️ Some tests failed! Check output for details. | 2 passed | 1 failed
```

## Configuration

### Async Behavior

Tests run asynchronously by default. You can control this behavior:

* **Globally:** In `Sert.run` set the `async` parameter to `false` to run tests synchronously by default
* **Per Module:** Set `_async` in your test module return table:
	* `_async = true`: Force async execution for this module
	* `_async = false`: Force sync execution for this module
	* `_async = nil`: Use global setting

### Sert.run Parameters

The `Sert.run` function accepts four parameters:

```lua
Sert.run(object: Instance, globals: Map?, async: boolean?, silent: boolean?)
```

1. `object`: The Instance to test or search for test modules in (required)
2. `globals`: A table of global variables to inject into test functions (optional)
3. `async`: If false, runs tests synchronously, defaults to true (optional)
4. `silent`: If true, suppresses console output and only returns results (optional)

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

## File Organization

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

* Tests can be placed alongside modules or organized in a dedicated test directory
* Test modules must end with `.test`

## Best Practices

* Use descriptive test names that explain the expected behavior
* Make specific assertions that test one behavior at a time
* Keep test modules close to the code they're testing
* Focus and skip tests to speed up the debug process
* Use lifecycle hooks to ensure proper cleanup between tests
* Consider disabling async for tests that may have race conditions

## 📄 License

This project is licensed under the [MIT License](LICENSE.txt).
