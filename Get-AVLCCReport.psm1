function Get-AVLCCReport {
	param(
		# The root directory of your AMUMSS install
		[string]$AmumssDir = "S:\AMUMSS\install",
		
		# If specified, we'll look for conflicts between the given Lua files instead of those reported by AMUMSS as having conflicts
		[string[]]$LuaFilePaths,
		
		# The path of "REPORT.lua" relative to $AmumssDir
		[string]$ReportLuaRelativeFilePath = "REPORT.lua",
		
		[switch]$ValidateOnly,
		
		[switch]$PassThru,
		
		# Regex to identify lines in REPORT.lua containing conflict information
		[string]$ConflictBlockRegex = '(?m)\[\[CONFLICT\]\] on "(.*)" \((.*)\)\r\n((.|\r\n)*?)IGNORE',
		[string]$ConflictLuaRegex = '- "SCRIPT in (.*)"',
		
		[string]$LuaTableJsonScriptPath = "S:\Git\Get-AVLCCReport\getLuaTableJson.lua",
		
		[switch]$Quiet,
		[switch]$Log,
		[string]$LogRelativePath = "",
		[string]$LogFileName = "Get-AVLCCReport",
		[string]$LogFileTimestampFormat = "yyyy-MM-dd_HH-mm-ss",
		[string]$LogLineTimestampFormat = "[HH:mm:ss] ",
		[string]$Indent = "    ",
		[string[]]$ExcludeLogCategories,
		[int]$Verbosity = 1
		
	)
	$logTs = Get-Date -Format $LogFileTimestampFormat
	$logPath = "$AmumssDir\$LogRelativePath\$($LogFileName)_$($logTs).log"
	
	$LOG_CATEGORIES = @(
		[PSCustomObject]@{ "Id" = 0; "Name" = "All" },
		[PSCustomObject]@{ "Id" = 1; "Name" = "Verbose" },
		[PSCustomObject]@{ "Id" = 2; "Name" = "Verboser" },
		[PSCustomObject]@{ "Id" = 3; "Name" = "Verbosest" },
		[PSCustomObject]@{ "Id" = 4; "Name" = "Many" },
		[PSCustomObject]@{ "Id" = 5; "Name" = "ManyVerbose" },
		[PSCustomObject]@{ "Id" = 6; "Name" = "ManyMany" },
		[PSCustomObject]@{ "Id" = 7; "Name" = "Error" },
		[PSCustomObject]@{ "Id" = 8; "Name" = "Success" }
	)
	$VERBOSITIES = @(
		[PSCustomObject]@{ "Id" = 1; "Excludes" = @("Verbose","Verboser","Verbosest","Many","ManyVerbose") },
		[PSCustomObject]@{ "Id" = 2; "Excludes" = @("Verboser","Verbosest","Many","ManyVerbose") },
		[PSCustomObject]@{ "Id" = 3; "Excludes" = @("Verbosest","Many","ManyVerbose") },
		[PSCustomObject]@{ "Id" = 4; "Excludes" = @("Many","ManyVerbose") },
		[PSCustomObject]@{ "Id" = 5; "Excludes" = @() }
	)
	if(-not $ExcludeLogCategories) {
		if($Verbosity -lt 5) {
			$ExcludeLogCategories = $VERBOSITIES | Where { $_.Id -eq $Verbosity } | Select -ExpandProperty "Excludes"
		}
	}
	
	$ErrorActionPreference = "Stop"
	
	function log {
		param (
			[Parameter(Position=0)]
			[string]$Msg = "",
			
			[string]$LogPath = $logPath,

			[int]$L = 0, # level of indentation
			[int[]]$C, # message categories, for filtering

			[ValidateScript({[System.Enum]::GetValues([System.ConsoleColor]) -contains $_})]
			[string]$FC = (get-host).ui.rawui.ForegroundColor, # foreground color
			[ValidateScript({[System.Enum]::GetValues([System.ConsoleColor]) -contains $_})]
			[string]$BC = (get-host).ui.rawui.BackgroundColor, # background color

			[switch]$E, # error
			[switch]$NoTS, # omit timestamp
			[switch]$NoNL, # omit newline after output
			[switch]$NoConsole, # skip outputting to console
			[switch]$NoLog # skip logging to file
		)
		
		if($Verbosity -le 0) { return }
		
		if($C -and $ExcludeLogCategories) {
			$breakOut = $false
			@($C) | ForEach-Object {
				$categoryId = $_
				$categoryName = $LOG_CATEGORIES | Where { $_.Id -eq $categoryId } | Select -ExpandProperty "Name"
				if($categoryName -in $ExcludeLogCategories) {
					$breakOut = $true
				}
			}
			if($breakOut) { return }
		}
		
		if($E) { $FC = "Red" }
		
		$ofParams = @{
			"FilePath" = $LogPath
			"Append" = $true
		}
		
		$whParams = @{}
		
		if($NoNL) {
			$ofParams.NoNewLine = $true
			$whParams.NoNewLine = $true
		}
		
		if($FC) { $whParams.ForegroundColor = $FC }
		if($BC) { $whParams.BackgroundColor = $BC }

		# Custom indent per message, good for making output much more readable
		for($i = 0; $i -lt $L; $i += 1) {
			$Msg = "$Indent$Msg"
		}

		# Add timestamp to each message
		# $NoTS parameter useful for making things like tables look cleaner
		if(-not $NoTS) {
			if($LogLineTimestampFormat) {
				$ts = Get-Date -Format $LogLineTimestampFormat
			}
			$Msg = "$ts$Msg"
		}

		# Check if this particular message is supposed to be logged
		if(-not $NoLog) {

			# Check if we're allowing logging
			if($Log) {
				
				# Check that the logfile already exists, and if not, then create it (and the full directory path that should contain it)
				if(-not (Test-Path -PathType "Leaf" -Path $LogPath)) {
					New-Item -ItemType "File" -Force -Path $LogPath | Out-Null
					log "Logging to `"$LogPath`"."
				}
				
				$Msg | Out-File @ofParams
			}
		}

		# Check if this particular message is supposed to be output to console
		if(-not $NoConsole) {

			# Check if we're allowing console output at all
			if(-not $Quiet) {
				Write-Host $Msg @whParams
			}
		}
	}

	function Get-LuaFiles($data) {
		log "Getting list of Lua files on which to act..."
		$anyGetFileErrors = $true
		
		if($LuaFilePaths) {
			log "-LuaFilePaths was specified. Using given Lua file paths." -L 1
			
			try {
				$conflictLuas = Get-GivenLuaFiles
			}
			catch {
				$conflictLuasError = $true
				log $_.Exception.Message -L 2 -E
			}
			
			if(-not $conflictLuasError) {
				$anyGetFileErrors = $false
			}
		}
		else {
			log "-LuaFilePaths was not specified. Interpreting Lua file paths from AMUMSS report file." -L 1
			try {
				$conflictMbins = Get-MbinFilesWithConflicts
			}
			catch {
				$conflictMbinsError = $true
				log $_.Exception.Message -L 2 -E
			}
			
			if(-not $conflictMbinsError) {
				try {
					$conflictLuas = Get-LuaFilesWithConflicts $conflictMbins
				}
				catch {
					$conflictLuasError = $true
					log $_.Exception.Message -L 2 -E
				}
			}
			
			if(-not $conflictLuasError) {
				$anyGetFileErrors = $false
			}
		}
		
		if($anyGetFileErrors) {
			log "Failed getting list of Lua files!" -L 1
		}
		else {
			$data | Add-Member -NotePropertyName "Luas" -NotePropertyValue $conflictLuas
		}
		$data.Errors = $anyGetFileErrors
		
		$data
	}
	
	function Get-GivenLuaFiles {
		log "Building Lua data from given Lua paths..." -L 1
		
		$conflictLuas = $LuaFilePaths | ForEach-Object {
			$lua = $_
			$otherLuas = $LuaFilePaths | Where { $_ -ne $lua }
			[PSCustomObject]@{
				"FilePath" = $lua
				"ConflictingLuas" = $otherLuas
			}
		}
		
		$luasCount = @($conflictLuas).count
		log "Found " -L 2 -NoNL
		log $luasCount -NoTS -FC "yellow" -NoNL
		log " unique Luas." -NoTS
		
		$conflictLuas | ForEach-Object {
			log $_.FilePath -L 3 -C 4
			
			$conflictingLuasCount = @($_.ConflictingLuas).count
			log "Found " -L 4 -NoNL -C 5
			log $conflictingLuasCount -NoTS -FC "yellow" -NoNL -C 5
			log " conflicting Luas." -NoTS -C 5
			$_.ConflictingLuas | ForEach-Object {
				log $_ -L 5 -C 5
			}
		}
		
		$conflictLuas
	}
	
	function Get-MbinFilesWithConflicts {
		$reportLuaFilePath = "$AmumssDir\$ReportLuaRelativeFilePath"
		log "Getting MBIN files with conflicts from `"$reportLuaFilePath`"..." -L 1
		
		$reportLuaFile = Get-Item -Path $reportLuaFilePath
		if(-not $reportLuaFile) {
			Throw "File `"$reportLuaFilePath`" not found!"
		}
		
		$reportLuaFileContent = $reportLuaFile | Get-Content -Raw
		if(-not $reportLuaFileContent) {
			Throw "No content found in `"$reportLuaFilePath`"!"
		}
		
		$conflictLinesMatchInfo = $reportLuaFileContent | Select-String -AllMatches -Pattern $ConflictBlockRegex
		if(-not $conflictLinesMatchInfo) {
			Throw "No conflicts found in `"$reportLuaFilePath`"!"
		}
		
		if(-not $conflictLinesMatchInfo.Matches) {
			Throw "Conflicts found, but no matches data was returned!"
		}
		
		$conflictLinesCount = @($conflictLinesMatchInfo.Matches).count
		if($conflictLinesCount -lt 1) {
			Throw "Conflicts found, and match data was returned, but the match count was <1!"
		}
		
		log "Found " -L 2 -NoNL
		log $conflictLinesCount -NoTS -FC "yellow" -NoNL
		log " MBIN files with conflicts." -NoTS
		
		$conflictMbins = $conflictLinesMatchInfo.Matches | ForEach-Object {
			$conflictMatch = $_
			$mbin = $conflictMatch.Groups[1].Value
			$pak = $conflictMatch.Groups[2].Value
			log "$mbin ($pak)" -L 3 -C 4
			
			$luaString = $conflictMatch.Groups[3].Value
			$luaMatchInfo = $luaString | Select-String -AllMatches -Pattern $ConflictLuaRegex
			if(-not $luaMatchInfo) {
				Throw "No Lua file paths recognized!"
			}
			
			if(-not $luaMatchInfo.Matches) {
				Throw "Lua files recognized, but no match data was returned!"
			}
			
			$luasCount = @($luaMatchInfo.Matches).count
			if($luasCount -lt 1) {
				Throw "Lua files recognized, and match data was returned, but the match count was <1!"
			}
			
			log "Found " -L 4 -NoNL -C 4
			log $luasCount -NoTS -FC "yellow" -NoNL -C 4
			log " contributing Luas." -NoTS -C 4
			$luaFiles = $luaMatchInfo.Matches | ForEach-Object {
				$luaMatch = $_
				$luaFilePath = $luaMatch.Groups[1].Value
				log $luaFilePath -L 5 -C 5
				$luaFilePathParts = $luaFilePath -split '\\'
				$luaFileNameIndex = $luaFilePathParts.length - 1
				$luaFileName = $luaFilePathParts[$luaFileNameIndex]
				$luaFileRelativeParentPath = $luaFilePath.Replace("\$luaFileName","")
				[PSCustomObject]@{
					"RelativeParentPath" = $luaFileRelativeParentPath
					"FileName" = $luaFileName
					"FilePath" = "$($AmumssDir)\$($luaFilePath)"
				}
			}
			
			
			[PSCustomObject]@{
				"Mbin" = $mbin
				"Pak" = $pak
				"Luas" = $luaFiles
				"Line" = $line.Value
			}
		}
		
		$conflictMbins
	}
	
	function Get-LuaFilesWithConflicts($conflictMbins) {
		# Currently we have a list of MBIN files.
		# Each MBIN file has a list of Luas that are trying to contribute to it.
		# Some Lua files may be contributing to multiple conflicts.
		# We only really care about the Lua files and which other Lua files they conflict with.
		# So instead, munge the data so that it's a list of Lua files, which each have a list of which other Lua files they conflict with.
		
		log "Converting list of MBINs which each have of a list of contributing Luas into a list of Luas which each contribute to a list of MBINs..." -L 1
		
		# Get unique Lua files
		$conflictLuas = $conflictMbins | ForEach-Object {
			$_.Luas | ForEach-Object {
				$_
			}
		} | Sort "FilePath" -Unique
		
		# For each Lua file record the list of MBINs it contributes to
		$conflictLuas = $conflictLuas | ForEach-Object {
			$lua = $_
			$mbins = $conflictMbins | ForEach-Object {
				if($_.Luas.FilePath -contains $lua.FilePath) {
					$_
				}
			}
			$lua | Add-Member -NotePropertyName "Mbins" -NotePropertyValue $mbins -PassThru
		}
		
		# For Lua file, generate a list of other Luas it conflicts with
		$conflictLuas = $conflictLuas | ForEach-Object {
			$lua = $_
			
			$conflictingLuaPaths = $lua.Mbins | ForEach-Object {
				$_.Luas | ForEach-Object {
					$_.FilePath
				}
			} | Sort
			$conflictingOtherLuaPaths = $conflictingLuaPaths | Where { $_ -ne $lua.FilePath }
			$conflictingOtherUniqueLuaPaths = $conflictingOtherLuaPaths | Select -Unique
			
			$lua | Add-Member -NotePropertyName "ConflictingLuas" -NotePropertyValue $conflictingOtherUniqueLuaPaths -PassThru
		}
		
		$luasCount = @($conflictLuas).count
		log "Found " -L 2 -NoNL
		log $luasCount -NoTS -FC "yellow" -NoNL
		log " unique Luas." -NoTS
		
		$conflictLuas | ForEach-Object {
			log $_.FilePath -L 3 -C 4
			
			$mbinsCount = @($_.Mbins).count
			log "Found " -L 4 -NoNL -C 4
			log $mbinsCount -NoTS -FC "yellow" -NoNL -C 4
			log " MBINs being contributed to." -NoTS -C 4
			$_.Mbins | ForEach-Object {
				log "$($_.Mbin) ($($_.Pak))" -L 5 -C 5
			}
			
			$conflictingLuasCount = @($_.ConflictingLuas).count
			log "Found " -L 4 -NoNL -C 4
			log $conflictingLuasCount -NoTS -FC "yellow" -NoNL -C 4
			log " conflicting Luas." -NoTS -C 4
			$_.ConflictingLuas | ForEach-Object {
				log $_ -L 5 -C 5
			}
		}
		
		$conflictLuas
	}
	
	function Get-LuaData($data) {
		# For each Lua file, get its NMS_MOD_DEFINITION_CONTAINER table, validate its syntax, and parse its data into forms that facilitate later comparison
		log "Getting Lua file data..."
		
		$anyOverallErrors = $false
		$processingCount = 0
		$luasCount = @($data.Luas).count
		$data.Luas = $data.Luas | ForEach-Object {
			$lua = $_
			$processingCount += 1
			log "Processing Lua " -L 1 -NoNL
			log "$($processingCount)/$($luasCount)" -NoTS -FC "yellow" -NoNL
			log ": `"$($lua.FilePath)`"..." -NoTS
			$anyGatheringErrors = $false
			
			# Get the Lua's effective NMS_MOD_DEFINITION_CONTAINER table data by executing the Lua script and passing that variable back
			$lua = Get-LuaTable $lua
			
			if(-not $lua.ExecutionErrors) {
				# Validate the table to make sure there aren't any anomalies
				$lua = Validate-LuaTable $lua
				
				if(
					(-not $ValidateOnly) -and
					(-not $lua.ValidationErrors)
				) {
					# Parse the table data into convenient forms for comparison
					$lua = Parse-LuaTable $lua
				}
				else {
					if($ValidateOnly) {
						if($lua.ValidationErrors) {
							log "-ValidateOnly was specified. Skipping parsing." -L 2
						}
						else {
							log "-ValidateOnly was specified and there were validation errors. Skipping parsing." -L 2
						}
					}
					elseif($lua.ValidationErrors) {
						log "There were validation errors. Skipping parsing." -L 2
					}
				}
			}
			
			if(
				($lua.ExecutionErrors) -or
				($lua.ValidationErrors) -or
				($lua.ParsingErrors)
			) {
				$anyGatheringErrors = $true
				$anyOverallErrors = $true
				log "This Lua file has one or more errors in execution, validation, and/or parsing!" -L 2 -E
			}
			$lua | Add-Member -NotePropertyName "GatheringErrors" -NotePropertyValue $anyGatheringErrors
			
			$lua
		}
		
		if($anyOverallErrors) {
			log "One or more Lua files had one or more errors in execution, validation, and/or parsing!" -L 1 -E
		}
		$data.Errors = $anyOverallErrors
		
		$data
	}
	
	function Get-LuaTable($lua) {
		log "Getting NMS_MOD_DEFINITION_CONTAINER table data..." -L 2 -C 1
		$anyExecutionErrors = $true
		
		$luaExeRelativePath = "MODBUILDER\Extras\lua_x64\bin\lua.exe"
		$luaExe = "$($AmumssDir)\$($luaExeRelativePath)"
		
		if(-not (Test-Path -PathType "Leaf" -Path $luaExe)) {
			log "Lua EXE not found at `"$luaExe`"!" -L 3 -E -C 1
		}
		else {
			if(-not (Test-Path -PathType "Leaf" -Path $LuaTableJsonScriptPath)) {
				log "Script not found at `"$LuaTableJsonScriptPath`"!" -L 3 -E -C 1
			}
			else {
				if(-not (Test-Path -PathType "Leaf" -Path $lua.FilePath)) {
					log "Lua file not found at `"$($lua.FilePath)`"!" -L 3 -E -C 1
				}
				else {
					log "Executing lua file table-to-JSON script: `"$LuaTableJsonScriptPath`"..." -L 3 -C 2
					try {
						$luaExeResult = & $luaExe $LuaTableJsonScriptPath $lua.FilePath *>&1
					}
					catch {
						log "Failed to execute script!" -L 4 -E -C 2
						log $_.Exception.Message -L 5 -E -C 2
					}
					
					$lastExitCodeBackup = $LASTEXITCODE
					if($lastExitCodeBackup -ne 0) {
						log "Script executed, but lua.exe returned a non-zero exit code (`"$lastExitCodeBackup`")!" -L 4 -E -C 2
						log $luaExeResult -L 5 -E -C 2
					}
					else {
						log "Script executed." -L 4 -FC "green" -C 2
						if($luaExeResult) {
							log "Result returned; interpreting as JSON." -L 3 -C 2
							$tableJson = $luaExeResult
							
							#log "Table data JSON string:" -L 3
							#log $tableJson -L 4
							
							log "Converting JSON into PowerShell object..." -L 3 -C 2
							try {
								$table = $tableJson | ConvertFrom-Json
								$anyExecutionErrors = $false
							}
							catch {
								log "Failed to convert JSON!" -L 4 -E -C 2
								log $_.Exception.Message -L 5 -E
							}
						}
						else {
							log "No result was returned!" -L 3 -E -C 2
						}
					}
					
					$lua | Add-Member -NotePropertyName "TableJson" -NotePropertyValue $tableJson
					$lua | Add-Member -NotePropertyName "Table" -NotePropertyValue $table
				}
			}
		}
				
		if($anyExecutionErrors) {
			log "Failed to get table data!" -L 3 -E -C 2
		}
		else {
			log "Succeeded getting table data." -L 3 -FC "green" -C 2
		}
		$lua | Add-Member -NotePropertyName "ExecutionErrors" -NotePropertyValue $anyExecutionErrors
		
		$lua
	}
	
	function Validate-LuaTable($lua) {
		log "Validating table data..." -L 2 -C 1
		$table = $lua.Table
		
		$validations = @()
		function Get-Validation($propertyName, $validation, $result) {
			$object = [PSCustomObject]@{
				"PropertyName" = $propertyName
				"Validation" = $validation
				"Result" = $result
			}
			$object
		}
		
		# Note: While everything in Lua is technically a table (https://www.lua.org/pil/11.html), going forward I'm going to use the term "array" to refer to tables whose only members are multiple un-named properties that are themselves tables. It's just simpler to say "an array of X members", instead of "a table of sub-tables with X members", to differentiate a table being used as a bucket of things from a table being used to host data and/or represent an object.
		
		# The MODIFICATIONS property is a required top-level property.
		# Check that it exists:
		$valid = $false
		if($table.MODIFICATIONS) {
			$valid = $true
		}
		$validations += Get-Validation "MODIFICATIONS" "exists" $valid
		
		# Technically, the spec says that the MODIFICATIONS property is an array, and can have multiple member tables: file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#MODIFICATIONS
		# However it seems nobody actually does this, and I don't know how that should be handled.
		# Babscoole said this was used "a little bit in the early days, but didn't pan out".
		# So, check that MODIFICATIONS array contains only one member:
		$valid = $false
		$count = @($table.MODIFICATIONS).count
		if($count -eq 1) {
			$valid = $true
		}
		$validations += Get-Validation "MODIFICATIONS" "has 1 member" $valid
		
		# MBIN_CHANGE_TABLE is the only valid property of the (hopefully one) MODIFICATIONS array member. It is a required property.
		# Check for existence of the MBIN_CHANGE_TABLE property:
		$valid = $false
		if($table.MODIFICATIONS[0].MBIN_CHANGE_TABLE) {
			$valid = $true
		}
		$validations += Get-Validation "MBIN_CHANGE_TABLE" "exists" $valid
		
		# MBIN_CHANGE_TABLE is an array.
		# Check that MBIN_CHANGE_TABLE is an array with 1 or more members.
		$valid = $false
		$mbinChangeCount = @($table.MODIFICATIONS[0].MBIN_CHANGE_TABLE).count
		if($count -ge 1) {
			$valid = $true
		}
		$validations += Get-Validation "MBIN_CHANGE_TABLE" "has >=1 member" $valid
		
		# Each member of the MBIN_CHANGE_TABLE array represents an action of some sort to enact upon a given MBIN file.
		# Each member must have an MBIN_FILE_SOURCE property, and an EXML_CHANGE_TABLE.
		# Each member of the MBIN_CHANGE_TABLE array can optionally also have a COMMENT property.
		
		# The EXML_CHANGE_TABLE must be an array of 1 or more members.
		# Each member of the EXML_CHANGE_TABLE array represents a change or set of changes to perform on one or more EXML values within the given MBIN file.
		# There are several types of changes that can be defined as part of an EXML_CHANGE_TABLE member: file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#EXML_CHANGE_TABLE
		# However the VALUE_CHANGE_TABLE type of change is by far the most common.
				
		# The only other valid actions besides changing an MBIN are discarding an MBIN, and performing REGEX actions, which seem to be pretty rare.
		# Ignoring these other possible actions for now.
		
		# Each member will have a required MBIN_FILE_SOURCE property.
		# Check that all members of the MBIN_CHANGE_TABLE array have a MBIN_FILE_SOURCE property:
		$valid = $false
		$mbinChangeFileSources = $table.MODIFICATIONS[0].MBIN_CHANGE_TABLE | Select "MBIN_FILE_SOURCE"
		if($mbinChangeFileSources) {
			$mbinChangeFileSourcesCount = @($mbinChangeFileSources).count
			if($mbinChangeFileSourcesCount -eq $mbinChangeCount) {
				# All of the members of MBIN_CHANGE_TABLE have a MBIN_FILE_SOURCE property.
				$valid = $true
			}
			else {
				if(@($mbinChangeFileSources).count -gt $mbinChangeCount) {
					# There are somehow more MBIN_FILE_SOURCE properties than members of MBIN_CHANGE_TABLE.
					# This should never happen.
				}
				if(@($mbinChangeFileSources).count -lt $mbinChangeCount) {
					# Only some of the members of MBIN_CHANGE_TABLE have a MBIN_FILE_SOURCE property.
					# Should still be more than 0, otherwise we wouldn't be here.
				}
			}
		}
		else {
			# None of the members of MBIN_CHANGE_TABLE have a MBIN_FILE_SOURCE property.
		}
		$validations += Get-Validation "MBIN_FILE_SOURCE" "all exist" $valid
		
		# Check that all members of the MBIN_CHANGE_TABLE array have a valid and populated MBIN_FILE_SOURCE property:
		# This seems less likely to happen. Will ignore this check for now.
		
		# Each member will have a required EXML_CHANGE_TABLE property.
		# Check that all members of the MBIN_CHANGE_TABLE array have a EXML_CHANGE_TABLE property:
		$valid = $false
		$mbinChangeExmlChanges = $table.MODIFICATIONS[0].MBIN_CHANGE_TABLE | Select "EXML_CHANGE_TABLE"
		if($mbinChangeExmlChanges) {
			$mbinChangeExmlChangesCount = @($mbinChangeExmlChanges).count
			if($mbinChangeExmlChangesCount -eq $mbinChangeCount) {
				# All of the members of MBIN_CHANGE_TABLE have a EXML_CHANGE_TABLE property.
				$valid = $true
			}
			else {
				if(@($mbinChangeExmlChanges).count -gt $mbinChangeCount) {
					# There are somehow more EXML_CHANGE_TABLE properties than members of MBIN_CHANGE_TABLE.
					# This should never happen.
				}
				if(@($mbinChangeExmlChanges).count -lt $mbinChangeCount) {
					# Only some of the members of MBIN_CHANGE_TABLE have a EXML_CHANGE_TABLE property.
					# Should still be more than 0, otherwise we wouldn't be here.
				}
			}
		}
		else {
			# None of the members of MBIN_CHANGE_TABLE have a EXML_CHANGE_TABLE property.
		}
		$validations += Get-Validation "EXML_CHANGE_TABLE" "all exist" $valid
		
		# Check that all members of the MBIN_CHANGE_TABLE array have a valid and populated EXML_CHANGE_TABLE property:
		# This seems less likely to happen. Will ignore this check for now.
		
		# EXML_CHANGE_TABLE is an array.
		# Check that each EXML_CHANGE_TABLE is an array with 1 or more members:
		$valid = $true
		$mbinChangeExmlChanges | ForEach-Object {
			$members = $_.EXML_CHANGE_TABLE
			$count = @($members).count
			if($count -lt 1) {
				$valid = $false
			}
			
		}
		$validations += Get-Validation "EXML_CHANGE_TABLE" "all have >=1 member" $valid
		
		# Record validation results
		$lua | Add-Member -NotePropertyName "Validations" -NotePropertyValue $validations
		
		# Output summary of validation results
		$anyValidationErrors = $false
		
		$validations | ForEach-Object {
			log "$($_.PropertyName) $($_.Validation): " -L 3 -NoNL -C 2
			
			$color = "green"
			if(-not $_.Result) {
				$color = "red"
				$anyValidationErrors = $true
			}
			log "$($_.Result)" -FC $color -NoTS -C 2
		}
		
		if($anyValidationErrors) {
			log "This Lua file failed validation!" -L 3 -E -C 1
		}
		else {
			log "All good." -L 3 -FC "green" -C 1
		}
		$lua | Add-Member -NotePropertyName "ValidationErrors" -NotePropertyValue $anyValidationErrors
		
		$lua
	}
	
	function Parse-LuaTable($lua) {
		log "Parsing table data..." -L 2 -C 1
		$table = $lua.Table
		$anyParsingErrors = $true
		
		# Parse value changes. These are the most common change that Luas perform.
		# file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#VALUE_CHANGE_TABLE
		$lua = Get-ValueChanges $lua
		
		if(-not $lua.ValueChangesErrors) {
			# Parse other possible functions: file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#NMS_MOD_DEFINITION_CONTAINER
			
			# file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#ADD
			#$lua = Get-Additions $lua
			
			# file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#REMOVE
			#$lua = Get-Removals $lua
			
			$anyParsingErrors = $false
		}
		
		if($anyParsingErrors) {
			log "This Lua file could not be parsed!" -L 3 -E -C 1
		}
		else {
			log "Succeeded parsing table data." -L 3 -FC "green" -C 1
		}
		$lua | Add-Member -NotePropertyName "ParsingErrors" -NotePropertyValue $anyParsingErrors
		
		$lua
	}
	
	function Get-ValueChanges($lua) {
		log "Identifying value changes..." -L 3 -C 2
		
		log "NOT YET IMPLEMENTED!" -L 4 -E -C 2
		
		$lua
	}
	
	function Test-ConflictPairIsUnique($targetPair, $pairs) {
		#log "Testing if `"$($targetPair.Luas)`" is unique..." -L 2
		$unique = $true
		$pairs | ForEach-Object {
			$thisPair = $_.Luas
			$commonMembers = 0
			$targetPair.Luas | ForEach-Object {
				#log "Testing if `"$_`" is in `"$thisPair`"..." -L 3
				if($_ -in $thisPair) {
					#log "It is." -L 4
					$commonMembers += 1
				}
				else {
					#log "It's not." -L 4
				}
			}
			if($commonMembers -gt 1) {
				#log "Not unique." -L 5
				$unique = $false
			}
		}
		
		if($unique) {
			#log "Unique." -L 5
		}
		
		$unique
	}
	
	function Get-ConflictPairs($data) {
		# Get full list of individual, 1-on-1 conflict pairings
		log "Getting conflict pairings..."
		
		log "Getting all pairings..." -L 1
		$conflictPairs = $data.Luas | ForEach-Object {
			$lua = $_
			$_.ConflictingLuas | ForEach-Object {
				[PSCustomObject]@{
					"Luas" = @($lua.FilePath, $_)
				}
			}
		}
		
		$conflictPairsCount = @($conflictPairs).count
		log "Found " -L 2 -NoNL
		log $conflictPairsCount -NoTS -FC "yellow" -NoNL
		log " total non-unique pairings." -NoTS
		
		$conflictPairs | ForEach-Object {
			$pair = $_.Luas
			$a = $pair[0]
			$b = $pair[1]
			log "`"$a`" " -L 3 -NoNL -C 4
			log "<>" -NoTS -FC "blue" -NoNL -C 4
			log " `"$b`"" -NoTS -C 4
		}
				
		# Every pairing will be duplicated
		log "Getting unique pairings..." -L 1
		$uniqueConflictPairs = $conflictPairs | ForEach-Object {
			$pair = $_
			$pair.Luas = $pair.Luas | Sort
			$pair
		} | Sort { $_.Luas[0],$_.Luas[1] } -Unique
		
		$uniqueConflictPairsCount = @($uniqueConflictPairs).count
		log "Found " -L 2 -NoNL
		log $uniqueConflictPairsCount -NoTS -FC "yellow" -NoNL
		log " unique conflict pairs." -NoTS
		
		$uniqueConflictPairs | ForEach-Object {
			$pair = $_.Luas
			$a = $pair[0]
			$b = $pair[1]
			log "`"$a`" " -L 3 -NoNL -C 4
			log "<>" -NoTS -FC "blue" -NoNL -C 4
			log " `"$b`"" -NoTS -C 4
		}
		
		$data | Add-Member -NotePropertyName "ConflictPairs" -NotePropertyValue $uniqueConflictPairs
		
		$data
	}
	
	function Compare-Luas($data) {
		log "Comparing Lua files..."
		
		$comparingCount = 0
		$conflictPairsCount = @($data.ConflictPairs).count
		$data.ConflictPairs | ForEach-Object {
			$comparingCount += 1
			$a = $_.Luas[0]
			$b = $_.Luas[1]			
			log "Comparing conflict pair " -L 1 -NoNL
			log "$($comparingCount)/$($conflictPairsCount)" -NoTS -FC "yellow" -NoNL
			log ": `"$a`" " -NoTS -NoNL
			log "<>" -NoTS -FC "blue" -NoNL
			log " `"$b`"" -NoTS
			
			# Compare directly conflicting actions 
			
			# Compare value changes
			$data = Compare-ValueChanges $data
			
			# Compare additions
			#$data = Compare-Additions $data
			
			# Compare removals
			#$data = Compare-Removals $data
			
			# and other possible functions: file:///S:/AMUMSS/install/README/README-AMUMSS_Script_Rules.html#NMS_MOD_DEFINITION_CONTAINER
			
			# Later, also attempt to compare logic errors.
			# e.g. One mod removes data that another mod later wants to add/edit (these will produce AMUMSS warnings)
			# or vice versa; one mod adds/edits data that another mod later wants to remove (these _probably_ wouldn't produce errors, but would be devious to troubleshoot
			
		}
		
		$data
	}
	
	function Compare-ValueChanges($data) {
		log "Comparing value changes..." -L 2 -C 1
		
		log "NOT YET IMPLEMENTED!" -L 3 -E -C 1
		
		$data
	}
	
	function Do-Stuff {
		$startTime = Get-Date
		$data = [PSCustomObject]@{
			"StartTime" = $startTime
			"Errors" = $false
		}
		
		$data = Get-LuaFiles $data
		
		if(-not $data.Errors) {
			$data = Get-LuaData $data
			
			if(-not $data.Errors) {
				$data = Get-ConflictPairs $data
				
				if(
					(-not $ValidateOnly) -and
					(-not $data.Errors)
				) {
					$data = Compare-Luas $data
				}
				else {
					if($ValidateOnly) {
						if($data.Errors) {
							log "-ValidateOnly was specified. Skipping comparison."
						}
						else {
							log "-ValidateOnly was specified and there were errors processing one or more Lua files. Skipping comparison."
						}
					}
					elseif($data.Errors) {
						log "There were errors processing one or more Lua files. Skipping comparison."
					}
				}
			}
		}
		
		$endTime = Get-Date
		$data | Add-Member -NotePropertyName "EndTime" -NotePropertyValue $endTime
		$runTime = $endTime - $startTime
		$data | Add-Member -NotePropertyName "RunTime" -NotePropertyValue $runTime
		log "Runtime: $runTime"
		
		if($PassThru) {
			$data
		}
	}
		
	Do-Stuff
	
	log "EOF"
}