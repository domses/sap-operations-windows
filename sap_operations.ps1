<#
	.SYNOPSIS
		Script to manage the Maintenance Tasks for SAP Systems
	
	.DESCRIPTION
		SAP Operations Script
	
	.PARAMETER mode
		The possible modes for this Script are:
			- StartALL (DEFAULT)
			- StopALL
	
	.PARAMETER delayInSeconds
		You can define a delayed execution of the script - for example to make sure some systems are starting prior others.
		Default: 0 Seconds
	
	.NOTES
		===========================================================================
		Created on:   	Windows
		Created by:   	Dominik Kastner
		Organization: 	DKIT
		Version:		0.9
		===========================================================================
#>
param
(
	[Parameter(Mandatory = $true,
			   Position = 0)]
	[String]$mode = "StartALL",
	[Parameter(Position = 1)]
	[int]$delayInSeconds = 0
)

# Change the width of the console
$Host.UI.RawUI.BufferSize = New-Object Management.Automation.Host.Size (500, 25)

Write-Verbose ON
# DEFAULT: SilentlyContinue
# DEBUG Mode: continue

$VerbosePreference = "continue"

# Error Preferece
$ErrorActionPreference = "Continue"
# OFF = SilentlyContinue

# Script Version
$global:ScriptVersion = "0.9"

# Define the enumerators

enum SystemType
{
	ABAP
	J2EE
	CS
}

enum DatabaseType
{
	ora
	hdb
	mss
	syb
	ada
	db2
}
enum Platform
{
	Windows
	Linux
}

enum InstanceType
{
	PAS
	ASCS
	SCS
}

enum Status
{
	Running
	Error
	Stopped
}



# Host-Class
class Host
{
	[String]$name
	[Platform]$platform
}

# Technical System class
# Represents a general technical system

class TechnicalSystem
{
}

# SAPSystem Class
# represents a technical system with type ABAP or J2EE with 1 or more technical instances
class SAPSystem: TechnicalSystem
{
	[String]$sid
	[SystemType]$systemType
	# Array of SAP instances
	[SAPApplicationServer[]]$sapApplServer
	[System.IO.FileInfo]$defaultProfile
	
	[Database]$db
	# stop system
	[bool] Stop()
	{
		# stop the system with the first found instance on the local host
		# Function StopSystem should stop all instances - even on Remote-Hosts
		
		
		Write-Host ((Get-Date -Format G) + " | INFO | " + "Stopping of system: " + $this.sid + " is initiated..") *>> $Script:logFile
		Write-Host ((Get-Date -Format G) + " | INFO | " + "Get Status of system..") *>> $Script:logFile
		
		# first check if system is already stopped
		if ($this.GetStatus() -eq [Status]::Stopped)
		{
			Write-Host ((Get-Date -Format G) + " | INFO | " + "SAP System " + $this.sid + " already stopped.") *>> $Script:logFile
			return $true
		}
		
		$localInstance = $this.sapApplServer | Where-Object { $_.applhost.name -eq $env:computername } | Select-Object -First 1
		
		
		# Build up the sapcontrol path
		$sapcontrolPath = Get-Item (($localInstance.exeDir.FullName).ToString() + '\sapcontrol.exe')
		
		if (!$?)
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + ("sapcontrol.exe cannot be found in path " + $localInstance.exeDir.FullName)) *>> $Script:logFile
			break
		}
		# build up the arguments for sapcontrol
		# this is maybe the only way to achieve this with & operator
		# there are no whitespaces allowed in the string
		# SAPCONTROL explanation
		# -prot PIPE : use windows named pipes - so no authentication is needed. Script executing user should be admin though
		# -nr : instance number of the system - can be any instance
		# -function StopSystem ALL : Stop the whole systems - all instances
		
		$sapcontrolParam = New-Object System.Collections.ArrayList
		$null = $sapcontrolParam.Add("-prot")
		$null = $sapcontrolParam.Add("PIPE")
		$null = $sapcontrolParam.Add("-nr")
		$null = $sapcontrolParam.Add($localInstance.instanceNr)
		$null = $sapcontrolParam.Add("-function")
		$null = $sapcontrolParam.Add("StopSystem")
		$null = $sapcontrolParam.Add("ALL")
		
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAPCONTROL Path: " + $sapcontrolPath.FullName + $sapcontrolParam) *>> $Script:logFile
		
		& $sapcontrolPath.FullName $sapcontrolParam *>> $null
		
		# Check if the exit code from sapcontrol is 0
		# 0 = success
		
		if ($lastexitcode -eq 0)
		{
			# wait 3 minutes and check the status
			Start-Sleep 180
			if ($this.GetStatus() -eq [Status]::Stopped)
			{
				Write-Host ((Get-Date -Format G) + " | INFO | " + "SAP System " + $this.sid + " succesfully stopped.") *>> $Script:logFile
				return $true
			}
			else
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP System " + $this.sid + " NOT succesfully stopped.") *>> $Script:logFile
				return $false
			}
			
		}
		else
		{
			# SAPCONTROL command failed..
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAPCONTROL command for System " + $this.sid + " failed.") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check SAPCONTROL command: " + $sapcontrolPath.FullName + " " + $sapcontrolParam) *>> $Script:logFile
		}
		# just in case
		# should not be reached
		return $false
	}
	
	# start system
	[bool] Start()
	{
		
		Write-Host ((Get-Date -Format G) + " | INFO | " + "Starting of SAP system " + $this.sid + " is initiated..") *>> $Script:logFile
		Write-Host ((Get-Date -Format G) + " | INFO | " + "Get Status of system") *>> $Script:logFile
		# first check if system is already runing
		if ($this.GetStatus() -eq [Status]::Running)
		{
			Write-Host ((Get-Date -Format G) + " | INFO | " + "SAP System " + $this.sid + " already started..") *>> $Script:logFile
			return $true
		}
		
		# first make sure the win SAPStartSrv services are running
		
		foreach ($applSrv in ($this.sapApplServer | Where-Object { $_.applhost.name -eq $env:computername }))
		{
			# Build up the sapcontrol path
			$sapcontrolPath = Get-Item (($applSrv.exeDir.FullName).ToString() + '\sapcontrol.exe')
			
			if (!$sapcontrolPath)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "sapcontrol.exe cannot be found in path" + $applSrv.exeDir.FullName) *>> $Script:logFile
				break
			}
			
			# build up the arguments for sapcontrol
			# this is maybe the only way to achieve this with & operator
			# there are no whitespaces allowed in the string
			# SAPCONTROL explanation
			# -prot PIPE : use windows named pipes - so no authentication is needed. Script executing user should be admin though
			# -nr : instance number of the system - can be any instance
			# -function StartService <SID> : Start the sapstartsrv of the specified instance
			
			$sapcontrolParamService = New-Object System.Collections.ArrayList
			$null = $sapcontrolParamService.Add("-prot")
			$null = $sapcontrolParamService.Add("PIPE")
			$null = $sapcontrolParamService.Add("-nr")
			$null = $sapcontrolParamService.Add($applSrv.instanceNr)
			$null = $sapcontrolParamService.Add("-function")
			$null = $sapcontrolParamService.Add("StartService")
			$null = $sapcontrolParamService.Add($this.sid)
			
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Start the SAPStartSrv services with command: " + $sapcontrolPath.FullName + " " + $sapcontrolParamService) *>> $Script:logFile
			
			# call sapcontrol
			& $sapcontrolPath.FullName $sapcontrolParamService *>> $null
			
			Start-Sleep -Seconds 10
			
			if ($lastexitcode -ne 0)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAPStartSrv of SAP System " + $this.sid + " NOT succesfully started..") *>> $Script:logFile
				return $false
				
			}
			
		}
		
		
		
		# retrieve instance from local host
		$localInstance = $this.sapApplServer | Where-Object { $_.applhost.name -eq $env:computername } | Select-Object -First 1
		
		# Build up the sapcontrol path
		$sapcontrolPath = Get-Item (($localInstance.exeDir.FullName).ToString() + '\sapcontrol.exe')
		
		if (!$sapcontrolPath)
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "sapcontrol.exe cannot be found in path" + $localInstance.exeDir.FullName) *>> $Script:logFile
			break
		}
		

		
		# build up the arguments for sapcontrol
		# this is maybe the only way to achieve this with & operator
		# there are no whitespaces allowed in the string
		# SAPCONTROL explanation
		# -prot PIPE : use windows named pipes - so no authentication is needed. Script executing user should be admin though
		# -nr : instance number of the system - can be any instance
		# -function StopSystem ALL : Stop the whole systems - all instances
		
		$sapcontrolParam = New-Object System.Collections.ArrayList
		$null = $sapcontrolParam.Add("-prot")
		$null = $sapcontrolParam.Add("PIPE")
		$null = $sapcontrolParam.Add("-nr")
		$null = $sapcontrolParam.Add($localInstance.instanceNr)
		$null = $sapcontrolParam.Add("-function")
		$null = $sapcontrolParam.Add("StartSystem")
		$null = $sapcontrolParam.Add("ALL")
		
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAPCONROL Path: " + $sapcontrolPath.FullName + " " + $sapcontrolParam) *>> $Script:logFile
		
		# call sapcontrol
		& $sapcontrolPath.FullName $sapcontrolParam *>> $null
		
		if ($lastexitcode -eq 0)
		{
			# wait 3 minutes and check the status
			Start-Sleep 180
			if ($this.GetStatus() -eq [Status]::Running)
			{
				Write-Host ((Get-Date -Format G) + " | INFO | " + "SAP System " + $this.sid + " succesfully started.") *>> $Script:logFile
				return $true
			}
			else
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP System " + $this.sid + " NOT succesfully started..") *>> $Script:logFile
				return $false
			}
			
		}
		else
		{
			# SAPCONTROL command failed..
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAPCONTROL command for System " + $this.sid + " failed.") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check SAPCONTROL command: " + $sapcontrolPath.FullName + " " + $sapcontrolParam) *>> $Script:logFile
		}
		# just in case
		# should not be reached
		return $false
	}
	
	[Status] GetStatus()
	{
		# system status calculation
		# if all instances are in status STOPPED then the overall status is STOPPED
		# if there is one ore more instances in status ERROR or STOPPED then the overall status is ERROR
		# Otherwise the overall status is RUNNING
		
		$systemstatus = [Status]::Running
		
		# if all instances are in status STOPPED then the overall status is STOPPED
		$stoppedCount = 0
		$errorCount = 0
		$instancesCount = $this.sapApplServer.Length
		foreach ($applServer in $this.sapApplServer)
		{
			$instanceStatus = $applServer.GetStatus()
			if ($instanceStatus -eq [Status]::Stopped)
			{
				$stoppedCount++
				
			}
			elseif ($instanceStatus -eq [Status]::Error)
			{
				$errorCount++
			}
			
		}
		# if all instances are stopped - then overall status is stopped
		if ($stoppedCount -eq $instancesCount)
		{
			$systemstatus = [Status]::Stopped
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated System status for " + $this.sid + " : " + $systemstatus) *>> $Script:logFile
			return $systemstatus
		}
		
		if (($stoppedCount -gt 0) -or ($errorCount -gt 0))
		{
			$systemstatus = [Status]::Error
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated System status for " + $this.sid + " : " + $systemstatus) *>> $Script:logFile
			return $systemstatus
		}
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated System status for " + $this.sid + " : " + $systemstatus) *>> $Script:logFile
		return $systemstatus
	}
}

# SAPApplicationServer Class
# represents a technical instance with a sapstartsrv process
class SAPApplicationServer
{
	[String]$instanceName
	[InstanceType]$instanceType
	[String]$instanceNr
	[Host]$applHost
	[System.IO.DirectoryInfo]$exeDir
	[System.IO.FileInfo]$instanceProfile
	
	# stop instance
	# not implemented yet
	# no use case so far for stopping a single instance
	[bool] Stop()
	{
		return $true
	}
	
	# start instance
	# not implemented yet
	# no use case so far for stopping a single instance
	[bool] Start()
	{
		return $true
	}
	
	[Status] GetStatus()
	{
		# Calculate status for the whole instance
		# When there are all process in status GREY then overall status is STOPPED
		# When there is 1 or more process in status RED or YELLOW then overall status is ERROR
		# Otherwise the overall status is GREEN
		
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Getting the status of the instance " + $this.instanceName) *>> $Script:logFile
		$uri = ("http://" + $this.applHost.name + ":5" + $this.instanceNr + "13/SAPControl.cgi")
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "The called URL for sapstartsrv is: " + $uri) *>> $Script:logFile
		
		$processList = $null
		
		try
		{
			$processList = (Invoke-RestMethod -Method Post -Uri $uri `
											  -Body '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><soap:Body><GetProcessList xmlns="urn:SAPControl" /></soap:Body></soap:Envelope>' `
											  -ContentType 'text/xml; charset=utf-8').Envelope.Body.GetProcessListResponse.process.ChildNodes;
		}
		catch
		{
			Write-Host ((Get-Date -Format G) + " | VERBOSE | " + "SAPStartSRV is not responsive..") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | VERBOSE | " + "Please check if the SAP Services are running..") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | VERBOSE | " + "The called URL for sapstartsrv is: " + $uri) *>> $Script:logFile
			
			$instanceStatus = [Status]::Stopped
			return $instanceStatus
		}
		
		# Instance status - default running
		$instanceStatus = [Status]::Running
		
		$stoppedCount = 0
		$errorCount = 0
		
		$processCount = $processList.Count
		
		foreach ($process in $processList)
		{
			
			if ($process.dispstatus -eq "SAPControl-GRAY")
			{
				$stoppedCount++
				
			}
			elseif (($process.dispstatus -eq "SAPControl-YELLOW") -or ($process.dispstatus -eq "SAPControl-RED"))
			{
				$errorCount++
			}
			
		}
		# if all instances are stopped - then overall status is stopped
		if ($stoppedCount -eq $processCount)
		{
			$instanceStatus = [Status]::Stopped
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE |" + "Calculated status for instance " + $this.instanceName + " " + $instanceStatus) *>> $Script:logFile
			return $instanceStatus
		}
		
		if (($stoppedCount -gt 0) -or ($errorCount -gt 0))
		{
			$instanceStatus = [Status]::Error
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated status for instance " + $this.instanceName + " " + $instanceStatus) *>> $Script:logFile
			return $instanceStatus
		}
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated status for instance " + $this.instanceName + " " + $instanceStatus) *>> $Script:logFile
		return $instanceStatus
	}
}



# Database Class
# Represents a general database system
# this is just a basic class - the function gets implemented in the inherited classes
class Database: TechnicalSystem
{
	[Host]$dbhost
	[String]$dbHostnameAcess
	[DatabaseType]$dbtype
	[String]$dbsid
	[String]$sapsid
	[String]$dbinstanceNr
	[bool]$remoteDB
	$service = @()
	
	# stop the database using the windows service controller
	# should be ok in most cases - equals a hard stop
	[bool] Stop()
	{
		
		
		Write-Host ((Get-Date -Format G) + " | INFO | " + "Stopping database " + $this.dbtype + " with ID " + $this.dbsid) *>> $Script:logFile
		
		# Stop not stopped services
		$this.service | Where-Object { $_.Status -ne "Stopped" } | Stop-Service -Force
		
		Start-Sleep -Seconds 10
		
		if ($this.GetStatus() -eq [Status]::Stopped)
		{
			Write-Host ((Get-Date -Format G) + " | INFO | " + "Database " + $this.dbsid + " is successfully stopped.") *>> $Script:logFile
			return $true
		}
		Write-Host ((Get-Date -Format G) + " | ERROR | " + "Database " + $this.sid + " is NOT succesfully stopped.") *>> $Script:logFile
		return $false
		
	}
	
	[bool] Start()
	{
		
		Write-Host ((Get-Date -Format G) + " | INFO | " + "Starting database " + $this.dbtype + " with ID " + $this.dbsid) *>> $Script:logFile
		
		# Start not running services
		$this.service | Where-Object { $_.Status -ne "Running" } | Start-Service
		
		if ($this.GetStatus() -eq [Status]::Running)
		{
			Write-Host ((Get-Date -Format G) + " | INFO | " + "Database " + $this.dbsid + " is successfully started.") *>> $Script:logFile
			return $true
		}
		Write-Host ((Get-Date -Format G) + " | ERROR | " + "Database " + $this.dbsid + " is NOT succesfully started.") *>> $Script:logFile
		return $false
	}
	
	[Status] GetStatus()
	{
		# Return true if all services are running
		$status = [Status]::Running
		
		foreach ($serv in $this.service)
		{
			# check for Stopping services
		
			$pendingServs = Get-Service | Where-Object { ($_.Name -eq $serv.Name) -and (($_.Status -eq "StopPending") -or ($_.Status -eq "StartPending")) }
			
			if ($pendingServs)
			{
				Start-Sleep -Seconds 60
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Database " + $this.dbsid + " is still in status StartPending/StopPending. Wait 60 Seconds..") *>> $Script:logFile
			}
			
			$RunningServs = Get-Service | Where-Object { ($_.Name -eq $serv.Name) -and ($_.Status -eq "Running") }
			
			# when no running services
			if (!$RunningServs)
			{
				$status = [Status]::Stopped
			}
			
		}
		
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated status for database " + $this.dbsid + " is " + $status) *>> $Script:logFile
		return $status
	}
}

# Database MaxDB Class
# Represents a MaxDB Database
# inherits the Database class
class MaxDB: Database
{
	# x_cons is possible
	# usage: x_cons <database_name> show state
	# should be possible without authentication
	
}

# Database SAP ASE Class
# Represents a SAP ASE Database
# inherits the Database class
class SAPASE: Database
{
	
}

# Database MSSQL Class
# Represents a MSSQL Database
# inherits the Database class
class MSSQL: Database
{
	
}

# Database Oracle Class
# Represents a Oracle Database
# inherits the Database class
class Oracle: Database
{
	[System.IO.File]$tnsnamesFile
	[String]$dbPort
	Oracle()
	{
		
	}
	Oracle([Host]$dbhost, [String]$dbsid, [String]$sapsid, [String]$sapProfileDir)
	{
		# assign variables
		$this.dbsid = $dbsid
		$this.sapsid = $sapsid.ToUpper()
		$this.dbhost = $dbhost
		
		
		$tnsnamesORA = Get-ChildItem -Path $sapProfileDir -Include "tnsnames.ora" -Recurse
		
		if (!$tnsnamesORA)
		{
			# tnsnames.ora file cannot be deteced at the profile dir oder subdirs
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "No tnsnames.ora file found at path " + $sapProfileDir + " or in subdirs") *>> $Script:logFile
			return
		}
		
		# regex tnsnames file to retrieve HOST + PORT
		
		$tnsNamesContent = Get-Content $tnsnamesORA -Raw
		
		if (!$tnsNamesContent)
		{
			# tnsnames.ora cannot be read
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "tnsnames.ora file at path " + $tnsnamesORA + " cannot be read") *>> $Script:logFile
			return
		}
		
		# retrieve HOST
		#$Matches = $null
		
		if (-not ($tnsNamesContent -match ("(?<=HOST\s=\s).*(?=\))")))
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "HOST Property cannot be retrieved from tnsnamesfile at path " + $tnsnamesORA) *>> $Script:logFile
			return
		}
		
		$this.dbhost.name = $Matches[0]
		
		
		# retrieve Port
		#$Matches = $null
		
		if (-not ($tnsNamesContent -match ("(?<=PORT\s=\s).*(?=\))")))
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "PORT Property cannot be retrieved from tnsnamesfile at path " + $tnsnamesORA) *>> $Script:logFile
			return
		}
		
		$this.dbPort = $Matches[0]
		
	}
	
	[Status] GetStatus()
	{
		if ($this.remoteDB -eq $false)
		{
			# call the parent class - database method to check the local services
			return ([Database]$this).GetStatus()
		}
		else
		{
			if ((!$this.dbhost) -or (!$this.dbPort))
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Getting the status of oracle db not possible - There were some error in collecting the system data for oracle db") *>> $Script:logFile
				return [Status]::Error
			}
			# Check connection via a simple Port Check - this is not a full db check, there are reasons where this is check is true but the the db is not actually functional
			
			$tcpTestStatus = Test-NetConnection -ComputerName $this.dbhost.name -Port $this.dbPort | select -ExpandProperty TcpTestSucceeded
			
			if ($tcpTestStatus)
			{
				Write-Host ((Get-Date -Format G) + " | INFO | " + "Remote Oracle DB is running - checked via Port Check of Host " + $this.dbhost.name + " and db port " + $this.dbPort) *>> $Script:logFile
				return [Status]::Running
			}
			else
			{
				Write-Host ((Get-Date -Format G) + " | INFO | " + " Remote Oracle DB is NOT running - checked via Port Check of Host " + $this.dbhost.name + " and db port " + $this.dbPort) *>> $Script:logFile
				return [Status]::Stopped
			}
		}
		
	}
	
}

# Database Hana Class
# Represents a HANA Database
# inherits the Database Class
class Hana: Database
{
	
	Hana([Host]$dbhost, [String]$dbsid, [String]$sapsid)
	{
		# assign variables
		$this.dbsid = $dbsid
		$this.sapsid = $sapsid.ToUpper()
		$this.dbhost = $dbhost
		
		
		$sidFromReg = Get-ChildItem -Path HKLM:\SOFTWARE\SAP\ | Where-Object { $_.PSChildName -eq $this.sapsid }
		# 1. hdbuserstore -u SAPServiceDBE List
		# 2. Nach KEY DEFAULT suchen
		# 3. ENV: HOST:PORT
		if (!$sidFromReg)
		{
			# no sap sid is detected - something must be wrong because it was found already on this host
			Write-Host ((Get-Date -Format G) + " | INFO | " + "No coresponding SAP SID for db " + $this.dbsid + "  was detected from the registry") *>> $Script:logFile
			return
		}
		
		$hdbClientPathRAW = Get-ItemProperty -Path HKLM:$sidFromReg\Environment | Select-Object -ExpandProperty Path
		
		if (-not ($hdbClientPathRAW -match ("[A-Z][:][^;]+hdbclient+")))
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "HDBCLIENT Path can not be detected") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check the Path: " + $sidFromReg) *>> $Script:logFile
			return
		}
		
		# retrieve the path from regex matches variable
		# 0 = matched string
		$hdbclientDir = Get-Item $Matches[0]
		$hdbuserstore = Get-ChildItem -Path $hdbclientDir -Filter "hdbuserstore.exe"
		
		if (!$hdbuserstore)
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "HDBUSERSTORE not found in Path " + $hdbclientDir) *>> $Script:logFile
		}
		
		# build up the hdbusterstore command
		
		$hdbuserstoreParam = New-Object System.Collections.ArrayList
		$null = $hdbuserstoreParam.Add("-u")
		$null = $hdbuserstoreParam.Add("SAPService" + $this.sapsid)
		$null = $hdbuserstoreParam.Add("List")
		
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "HDBUSERSTORE Command :" + $hdbuserstore.FullName + " " + $hdbuserstoreParam) *>> $Script:logFile
		
		$hdbUserStoreOut = (& $hdbuserstore.FullName $hdbuserstoreParam) -join "`n"
		
		# match the DEFAULT KEY of the hdbuserstore output 
		# more exactly match the host+port so we can extract the instance number
		if (-not ($hdbUserStoreOut -match ("(?<=KEY\sDEFAULT\s{3}ENV\s:\s)(.*)(?=\s)")))
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "HOST+Port of hdbuserstore cannot be detected - please check KEY DEFAULT of hdbuserstore") *>> $Script:logFile
			return
		}
		
		# retrieve the path from regex matches variable
		# 0 = matched string
		$hdbuserstoreEntry = $Matches[0]
		
		# check if hdbuserstore output contains multiple hosts
		if ($hdbuserstoreEntry -Match ";")
		{
			
			$hdbuserstoreHostPort = $hdbuserstoreEntry.Split(";")
			# just use the first one
			$hdbuserstoreHostPort = $hdbuserstoreHostPort[0]
		}
		else
		{
			$hdbuserstoreHostPort = $hdbuserstoreEntry
		}
		
		if (!$hdbuserstoreEntry -match ":")
		{
			# Error in HDB User Store - no : found in syntax
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "HOST+Port of hdbuserstore is not correct - please check KEY DEFAULT of hdbuserstore") *>> $Script:logFile
			return
		}
		
		$hdbuserstoreHostPortTmp = $hdbuserstoreEntry.Split(":")
		$hdbuserstoreHost = $hdbuserstoreHostPortTmp[0]
		$hdbuserstorePort = $hdbuserstoreHostPortTmp[1]
		
		# Port number must be exact 5 chars
		# otherwise there is a problem
		if ($hdbuserstorePort.length -ne 5)
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "Port " + $hdbuserstorePort + " of hdbuserstore is not correct - please check KEY DEFAULT of hdbuserstore") *>> $Script:logFile
			return
		}
		
		# extract the instance nr from port
		$hdbInsNr = $hdbuserstorePort.Substring(1, 2)
		
		# assign instance nr
		$this.dbinstanceNr = $hdbInsNr
		
		# assign hostname for client access (could be different thank normal hostname, vHost alias etc)
		$this.dbHostnameAcess = $hdbuserstoreHost
		
		
	}
	[Status] GetStatus()
	{
		
		# Calculate status for the whole instance
		# When there are all process in status GREY then overall status is STOPPED
		# When there is 1 or more process in status RED or YELLOW then overall status is ERROR
		# Otherwise the overall status is GREEN
		
		# Instance status - default running
		$instanceStatus = [Status]::Running
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Getting the status of the HANA instance " + $this.dbsid) *>> $Script:logFile
		$uri = ("http://" + $this.dbHostnameAcess + ":5" + $this.dbinstanceNr + "13/SAPControl.cgi")
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "The called URL for sapstartsrv is: " + $uri) *>> $Script:logFile
		
		$processList = $null
		
		try
		{
			$processList = (Invoke-RestMethod -Method Post -Uri $uri `
											  -Body '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><soap:Body><GetProcessList xmlns="urn:SAPControl" /></soap:Body></soap:Envelope>' `
											  -ContentType 'text/xml; charset=utf-8').Envelope.Body.GetProcessListResponse.process.ChildNodes;
		}
		catch
		{
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAPStartSRV is not responsive..") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check if the SAP Services are running..") *>> $Script:logFile
			Write-Host ((Get-Date -Format G) + " | Error | " + "The called URL for sapstartsrv is: " + $uri) *>> $Script:logFile
			
			# status is stopped when service is not running
			$instanceStatus = [Status]::Stopped
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE |" + "Calculated status for instance " + $this.dbsid + " " + $instanceStatus) *>> $Script:logFile
			
			return $instanceStatus
		}
		
		
		$stoppedCount = 0
		$errorCount = 0
		
		$processCount = $processList.Count
		
		foreach ($process in $processList)
		{
			
			if ($process.dispstatus -eq "SAPControl-GRAY")
			{
				$stoppedCount++
				
			}
			elseif (($process.dispstatus -eq "SAPControl-YELLOW") -or ($process.dispstatus -eq "SAPControl-RED"))
			{
				$errorCount++
			}
			
		}
		# if all instances are stopped - then overall status is stopped
		if ($stoppedCount -eq $processCount)
		{
			$instanceStatus = [Status]::Stopped
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE |" + "Calculated status for instance " + $this.dbsid + " " + $instanceStatus) *>> $Script:logFile
			return $instanceStatus
		}
		
		if (($stoppedCount -gt 0) -or ($errorCount -gt 0))
		{
			$instanceStatus = [Status]::Error
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated status for instance " + $this.dbsid + " " + $instanceStatus) *>> $Script:logFile
			return $instanceStatus
		}
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Calculated status for instance " + $this.dbsid + " " + $instanceStatus) *>> $Script:logFile
		return $instanceStatus
		
	}
	
}



class SAPTechnicalSystemHelper
{
	[System.Collections.ArrayList]$technicalSystems = @()
	
	[System.Collections.ArrayList] GetTechnicalSystemsFromDiscovery()
	{
		$this.GetDatabases()
		$this.GetSAPSystems()
		
		
		return $this.technicalSystems
	}
	
	[void] GetSAPSystems()
	{
		
		# Detect ALL SAP Systems
		
		
		# 1. SAP Systems Type ABAP+J2EE
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP System detection in progress..") *>> $Script:logFile
		# Extract all keys from SAP directory
		# TODO:
		# - Check if ITEM-Property ..Environment\SAPSYSTEMNAME AND SAPEXE is available
		$sidsFromREG = Get-ChildItem -Path HKLM:\SOFTWARE\SAP\ | Where-Object { $_.PSChildName.Length -eq 3 }
		
		if (!$sidsFromREG)
		{
			Write-Host ((Get-Date -Format G) + " | INFO | " + "No SIDS from the registry detected - please check if there are any sap systems installed") *>> $Script:logFile
			return
		}
		
		# loop throgh the detected SIDs
		
		foreach ($sid in $sidsFromREG)
		{
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected SID from the registry: " + $sid.PSChildName) *>> $Script:logFile
			
			# Get important Values from the registry
			# should be available on a default installation
			#$sidREG = Get-ItemPropertyValue -Path HKLM:$sid\Environment -Name SAPSYSTEMNAME
			$sidREG = Get-ItemProperty -Path HKLM:$sid\Environment | Select-Object -ExpandProperty SAPSYSTEMNAME
			
			if (!$sidREG)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Cannot get the KEY SAPSYSTEMNAME from the registry.") *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check the Registry: " + $sid.Name) *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Skipping the sid " + $sid) *>> $Script:logFile
				continue
			}
			
			$sapexeREG = Get-ItemProperty -Path HKLM:$sid\Environment | Select-Object -ExpandProperty SAPEXE
			if (!$sapexeREG)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Cannot get the KEY SAPEXE from the registry.") *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check the Registry: " + $sid.Name) *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Skipping the sid " + $sid) *>> $Script:logFile
				continue
			}
			
			# Get the SystemRoot
			# eg. E:\usr\sap\<SID>
			$sapSystemRoot = $null
			if (-not ($sapexeREG -match ("^(.*\\usr\\sap\\" + [regex]::escape($sidREG) + ").*$")))
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP System root cannot be detected.") *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check the Path: " + $sapexeREG.Name) *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Skipping the sid " + $sid) *>> $Script:logFile
				continue
			}
			
			# retrieve the path from regex matches variable
			# 1 = matched string
			$sapSystemRoot = Get-Item $Matches[1]
			
			if (!$sapSystemRoot)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP System root is not available in filesystem.") *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Please check the Path: " + $Matches[1]) *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Skipping the sid " + $sid) *>> $Script:logFile
				continue
			}
			
			$sapProfileDir = Get-Item ($sapSystemRoot.FullName + "\SYS\profile")
			$sapDefaultProfile = Get-Item ($sapProfileDir.FullName + "\DEFAULT.PFL")
			
			
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP system root: " + $sapSystemRoot.FullName) *>> $Script:logFile
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP profile dir: " + $sapProfileDir.FullName) *>> $Script:logFile
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP default profile: " + $sapDefaultProfile.FullName) *>> $Script:logFile
			
			# Check if DEFAULT Profile is available
			if ((Test-Path $sapDefaultProfile) -eq $false)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "DEFAULT profile not available: " + $sapDefaultProfile.Name) *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Skipping the sid " + $sid) *>> $Script:logFile
				continue
			}
			# Get the system type from the DEFAULT profile - system/type
			$systemType = Get-Content -Path $sapDefaultProfile |
			Where-Object { $_ -match "[\s]{0,}system\/type[\s]{0,}=[\s]{0,}([A-Z0-9]+)" } |
			ForEach-Object { $matches[1] }

			# When system type is not set, it could be a SAP Content Server

			if (@(Get-ChildItem $sapProfileDir | Get-Content | Where-Object { $_ -match "icm/HTTP/contentserver_0" }).Length -gt 0)
			{
				$systemType = "CS"
			}
			
			
			if (!$systemType)
			{
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "ERROR: The system type cannot be detected.") *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Check the parameter system/type parameter in the default profile") *>> $Script:logFile
				Write-Host ((Get-Date -Format G) + " | ERROR | " + "Skipping the sid " + $sid) *>> $Script:logFile
				continue
			}
			elseif (($systemType -ne "ABAP") -and ($systemType -ne "J2EE") -and ($systemType -ne "CS"))
			{
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "system not from type ABAP or J2EE.. skipping") *>> $Script:logFile
				continue
			}
			
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected system type: " + $systemType) *>> $Script:logFile
			
			
			# Technical system
			$technicalSystem = $null
			$instanceNames = $null
			
			switch ($systemType)
			{
				"ABAP"
				{
					$technicalSystem = New-Object SAPSystem
					$technicalSystem.sid = $sidREG
					$technicalSystem.systemType = [SystemType]::ABAP
					$technicalSystem.defaultProfile = $sapDefaultProfile
					
					# Get The application servers
					# Possible Types for ABAP
					# DVEBMGSXX
					# DXX
					# ASCSXX
					$instanceNames = Get-ChildItem -Path $sapSystemRoot -Directory | ForEach-Object { if ($_.Name -match "^DVEBMGS[0-9]{2}|ASCS[0-9]{2}|D[0-9]{2}$") { $_.Name } }
					
					if ($null -eq $instanceNames)
					{
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "no instances detected - please check if there is the instance directory under the system-root available") *>> $Script:logFile
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "System-Root: {0}" -f $sapSystemRoot.FullName) *>> $Script:logFile
						continue
					}
					Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Instance names: " + $instanceNames) *>> $Script:logFile
				}
				"J2EE"
				{
					$technicalSystem = New-Object SAPSystem
					$technicalSystem.sid = $sidREG
					$technicalSystem.systemType = [SystemType]::J2EE
					$technicalSystem.defaultProfile = $sapDefaultProfile
					
					# Get The Application Servers
					# Possible Types for J2EE
					# JXX
					# SCSXX
					$instanceNames = Get-ChildItem -Path $sapSystemRoot -Directory | ForEach-Object { if ($_.Name -match "^J[0-9]{2}|SCS[0-9]{2}$") { $_.Name } }
					if ($null -eq $instanceNames)
					{
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "no instances detected - please check if there is the instance directory under the system-root available") *>> $Script:logFile
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "System-Root: {0}" -f $sapSystemRoot.FullName) *>> $Script:logFile
						exit
					}
					Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Instance names: " + $instanceNames) *>> $Script:logFile
					
					
				}
				"CS"
				{
					$technicalSystem = New-Object SAPSystem
					$technicalSystem.sid = $sidREG
					$technicalSystem.systemType = [SystemType]::CS
					$technicalSystem.defaultProfile = $sapDefaultProfile
					
					# Get The Application Servers
					# CXX
					$instanceNames = Get-ChildItem -Path $sapSystemRoot -Directory | ForEach-Object { if ($_.Name -match "^C[0-9]{2}$") { $_.Name } }
					if ($null -eq $instanceNames)
					{
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "no instances detected - please check if there is the instance directory under the system-root available") *>> $Script:logFile
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "System-Root: {0}" -f $sapSystemRoot.FullName) *>> $Script:logFile
						exit
					}
					Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Instance names: " + $instanceNames) *>> $Script:logFile
					# detect all instances and the database
					
					foreach ($instanceName in $instanceNames)
					{
						# extracting instanceNR
						$instanceNr = $instanceName.Substring($instanceName.Length - 2, 2)
						
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detecting information for instance " + $instanceName) *>> $Script:logFile
						# Get the instance profile
						# there should be just one with the pattern <SID>_<instanceName>_<HOST>*
						# backups should contain a point
						# TODO: implement a check if multiple profiles are detected
						$instProfile = Get-ChildItem -Path $sapProfileDir -File | Where-Object { $_.Name -match ("^" + $sidREG + "_" + $instanceName + "_[^.\s]+$") }
						if (!$instProfile)
						{
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP instance profile cannot be found.") *>> $Script:logFile
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "Check path " + $sapProfileDir) *>> $Script:logFile
							continue
						}
						$hostname = $instProfile.Name.Substring(($instProfile.Name.LastIndexOf("_") + 1), ($instProfile.Name.Length - ($instProfile.Name.LastIndexOf("_") + 1)))
						
						# Get the EXE Path from the sap application server Service
						# Process: sapstartsrv.exe
						# TODO: use replace with REGEX
						
						$sapexePath = Get-Item (Get-WmiObject win32_service |
							Where-Object { $_.Name -eq ("SAP" + $sidREG + "_" + $instanceNr) } |
							ForEach-Object { ($_.PathName.Substring(0, ($_.PathName.IndexOf("sapstartsrv.exe") - 1))).Trim('"') })
						
						if (!$sapexePath)
						{
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP-Executable Path cannot be found - please check the Windows Service {0}" -f ("SAP" + $sidREG + "_" + $instanceNr)) *>> $Script:logFile
							exit
						}
						
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance name: " + $instanceName) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance profile: " + $instProfile.Name) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP exe path: " + $sapexePath.FullName) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance hostname: " + $hostname) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance nr: " + $instanceNr) *>> $Script:logFile
						
						$instance = New-Object SAPApplicationServer
						$instance.instanceName = $instanceName
						$instance.instanceNr = $instanceNr
						$instance.instanceProfile = $instProfile
						$instance.applHost = New-Object Host
						$instance.applHost.Platform = [Platform]::Windows
						$instance.applHost.name = $hostname
						$instance.exeDir = $sapexePath
						
						# Add the instance to the sapsystem class
						$technicalSystem.sapApplServer += $instance
						
					}
					
				}

				{ ($_ -eq "ABAP") -or ($_ -eq "J2EE") }
				{
					# detect all instances and the database
					
					foreach ($instanceName in $instanceNames)
					{
						# extracting instanceNR
						$instanceNr = $instanceName.Substring($instanceName.Length - 2, 2)
						
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detecting information for instance " + $instanceName) *>> $Script:logFile
						# Get the instance profile
						# there should be just one with the pattern <SID>_<instanceName>_<HOST>*
						# backups should contain a point
						# TODO: implement a check if multiple profiles are detected
						$instProfile = Get-ChildItem -Path $sapProfileDir -File | Where-Object { $_.Name -match ("^" + $sidREG + "_" + $instanceName + "_[^.\s]+$") }
						if (!$instProfile)
						{
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP instance profile cannot be found.") *>> $Script:logFile
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "Check path " + $sapProfileDir) *>> $Script:logFile
							continue
						}
						$hostname = $instProfile.Name.Substring(($instProfile.Name.LastIndexOf("_") + 1), ($instProfile.Name.Length - ($instProfile.Name.LastIndexOf("_") + 1)))
						
						# Get the EXE Path from the sap application server Service
						# Process: sapstartsrv.exe
						# TODO: use replace with REGEX
						
						$sapexePath = Get-Item (Get-WmiObject win32_service |
							Where-Object { $_.Name -eq ("SAP" + $sidREG + "_" + $instanceNr) } |
							ForEach-Object { ($_.PathName.Substring(0, ($_.PathName.IndexOf("sapstartsrv.exe") - 1))).Trim('"') })
						
						if (!$sapexePath)
						{
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAP-Executable Path cannot be found - please check the Windows Service {0}" -f ("SAP" + $sidREG + "_" + $instanceNr)) *>> $Script:logFile
							exit
						}
						
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance name: " + $instanceName) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance profile: " + $instProfile.Name) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP exe path: " + $sapexePath.FullName) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance hostname: " + $hostname) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "SAP instance nr: " + $instanceNr) *>> $Script:logFile
						
						$instance = New-Object SAPApplicationServer
						$instance.instanceName = $instanceName
						$instance.instanceNr = $instanceNr
						$instance.instanceProfile = $instProfile
						$instance.applHost = New-Object Host
						$instance.applHost.Platform = [Platform]::Windows
						$instance.applHost.name = $hostname
						$instance.exeDir = $sapexePath
						
						# Add the instance to the sapsystem class
						$technicalSystem.sapApplServer += $instance
						
					}
					
					# Get the dbms type from the DEFAULT profile - dbms/type
					$dbtype = Get-Content -Path $technicalSystem.defaultProfile |
					Where-Object { $_ -match "[\s]{0,}dbms\/type[\s]{0,}=[\s]{0,}([A-Z0-9]+)" } |
					ForEach-Object { $matches[1] }
					
					if (!$dbtype)
					{
						# try to get the DBMS from Registry
						$dbtype = Get-ItemProperty -Path HKLM:$sid\Environment | Select-Object -ExpandProperty DBMS_TYPE
						if (!$dbtype)
						{
							Write-Host ((Get-Date -Format G) + " | ERROR | " + "dbms\type parameter cannot be detected in DEFAULT profile or from REGISTRY.") *>> $Script:logFile
							continue
						}
						
					}
					Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected Database type from dbms/type Parameter in DEFAULT Profile: " + $dbtype) *>> $Script:logFile
					
					# Get the db host
					
					$sapdbhost = Get-Content -Path $technicalSystem.defaultProfile |
					Where-Object { $_ -match "[\s]{0,}SAPDBHOST[\s]{0,}=[\s]{0,}([A-Z0-9]+)" } |
					ForEach-Object { $matches[1] }
					
					
					if (!$sapdbhost)
					{
						Write-Host ((Get-Date -Format G) + " | ERROR | " + "SAPDBHOST parameter cannot be detected in DEFAULT profile..") *>> $Script:logFile
						continue
					}
					Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected database host from SAPDBHOST parameter in DEFAULT profile: " + $sapdbhost) *>> $Script:logFile
					
					# Search in detected databases
					# First check if there is ab DB with SID matching the SAPSID - if true, assign this DB
					# Otherwise check the found dbs\<dbtype>\dbname from Profile
					# if not found - database must be on an other host
					#$this.GetDatabases()
					
					$dblocal = $this.technicalSystems | Where-Object { $_ -is [Database] } | Where-Object { $_.dbsid -eq $sidREG }
					
					if ($dblocal)
					{
						# set remoteDB to false
						$dblocal.remoteDB = $false
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "The database for sap system " + $technicalSystem.sid + " is on the same host") *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Database type: " + $dblocal.dbtype) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Database sid: " + $dblocal.dbsid) *>> $Script:logFile
						# assign database to the sap system
						$technicalSystem.db = $dblocal
						
						# remove it from the technical systems list, because it is already assigned to the system
						# only standalone database should remain in the technical systems list
						$this.technicalSystems.Remove($dblocal)
					}
					else
					{
						
						$db = $null
						
						switch ($dbtype)
						{
							"hdb" {
								
								# look in the default profile for parameter dbs\<dbtype>\dbname
								# Get the db sid
								$dbsidProfile = Get-Content -Path $technicalSystem.defaultProfile |
								Where-Object { $_ -match "[\s]{0,}dbs\/[a-z]{3}\/dbname[\s]{0,}=[\s]{0,}([A-Z0-9]+)" } |
								ForEach-Object { $matches[1] }
								
								if (!$dbsidProfile)
								{
									# the parameter dbs\<dbtype>\dbname is not found in the profile
									Write-Host ((Get-Date -Format G) + " | ERROR | " + "ON HANA System: dbs\<dbtype>\dbname cannot be detected..") *>> $Script:logFile
									continue
								}
								
								
								# create database object
								$dbhost = New-Object Host
								$dbhost.name = $sapdbhost
								$db = [Hana]::new($dbhost, $dbsidProfile, $technicalSystem.sid)
								
								$db.remoteDB = $true
								$db.dbtype = $dbtype
								
							}
							"ora" {
								
								# look in the default profile for parameter dbs\<dbtype>\dbname
								# Get the db sid
								$dbsidProfile = Get-Content -Path $technicalSystem.defaultProfile |
								Where-Object { $_ -match "[\s]{0,}dbs\/[a-z]{3}\/dbname[\s]{0,}=[\s]{0,}([A-Z0-9]+)" } |
								ForEach-Object { $matches[1] }
								
								if (!$dbsidProfile)
								{
									# the parameter dbs\<dbtype>\dbname is not found in the profile
									Write-Host ((Get-Date -Format G) + " | VERBOSE | " + "ON ORACLE System: dbs\<dbtype>\dbname cannot be detected.. now check in registry for ORACLE_SID") *>> $Script:logFile
									# check in registry for ORACLE_SID
									
									
									$oraSIDFromREG = Get-ItemProperty -Path ("HKLM:\SOFTWARE\SAP\" + $technicalSystem.sid + "\Environment") | Select-Object -ExpandProperty ORACLE_SID
									
									if (!$oraSIDFromREG)
									{
										Write-Host ((Get-Date -Format G) + " | ERROR | " + "No SID found also in registry - cannot proceed. Please Check ORACLE_SID ENV variable in registry.") *>> $Script:logFile
										continue
									}
									
								}
								
								
								# create database object
								$dbhost = New-Object Host
								$dbhost.name = $sapdbhost
								$db = [Oracle]::new($dbhost, $dbsidProfile, $technicalSystem.sid, $technicalSystem.defaultProfile.Directory)
								
								$db.remoteDB = $true
								$db.dbtype = $dbtype
							}
							default {
								# create database object
								$db = New-Object Database
								$db.remoteDB = $true
								$db.dbhost = New-Object Host
								$db.dbhost.name = $sapdbhost
								$db.dbtype = $dbtype
								# $db.dbsid = $dbsidProfile
							}
						}
						
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "The database for sap system " + $technicalSystem.sid + " is NOT on the same host") *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Database type: " + $db.dbtype) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Database sid: " + $db.dbsid) *>> $Script:logFile
						
						$technicalSystem.db = $db
						
					}
					
					
					
				}


			}
			$this.technicalSystems.Add($technicalSystem)
		}
	}
	
	[void] GetDatabases()
	{
		
		# Detect ALL SAP Systems
		
		# Detect databases
		$databases = @()
		
		Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Database detection in progress..") *>> $Script:logFile
		
		# MAXDB
		# Detected it from the windows services - MaxDB service "SAP DBTech-<SID>"
		$MaxDBServices = Get-Service | Where-Object { $_.Name -match "^SAP DBTech-[A-Z0-9]{3}$" }
		
		# when maxdb databases are found
		if ($MaxDBServices)
		{
			
			# construct the maxDB objects
			foreach ($MaxDBService in $MaxDBServices)
			{
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected MaxDB service: " + $MaxDBService.Name) *>> $Script:logFile
				$maxdb = New-Object MaxDB
				
				# Set the hostname
				# Must be running on the same computer -> set it to its own hostname
				$dbhost = New-Object Host
				$dbhost.name = $env:computername
				$dbhost.Platform = [Platform]::Windows
				
				$maxdb.dbhost = $dbhost
				$maxdb.dbtype = [DatabaseType]::ada
				$maxdb.dbsid = ($MaxDBService.Name -replace "SAP DBTech-", "")
				$maxdb.service = $MaxDBService
				$databases += $maxdb
				
			}
		}
		else
		{
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "No MaxDB detected ") *>> $Script:logFile
		}
		
		# SAP ASE
		# Detected it from the windows services - MaxDB service "SYBSQL_<SID>"
		$SAPASEServices = Get-Service | Where-Object { $_.Name -match "^SYBSQL_[A-Z0-9]{3}$" }
		
		# when maxdb databases are found
		if ($SAPASEServices)
		{
			
			# construct the maxDB objects
			foreach ($SAPASEService in $SAPASEServices)
			{
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected SAP ASE services: " + $SAPASEService.Name) *>> $Script:logFile
				$sapase = New-Object SAPASE
				
				# Set the hostname
				# Must be running on the same computer -> set it to its own hostname
				$dbhost = New-Object Host
				$dbhost.name = $env:computername
				$dbhost.Platform = [Platform]::Windows
				
				$sapase.dbhost = $dbhost
				$sapase.dbtype = [DatabaseType]::syb
				$sapase.dbsid = ($SAPASEService.Name -replace "SYBSQL_", "")
				$sapase.service += $SAPASEService
				
				# get additional services
				# ASE Backup Server "SYBBCK_<SID>_BS"
				$sapase.service += Get-Service | Where-Object { $_.Name -match "^SYBBCK_" + [regex]::escape($sapase.dbsid) + "_BS$" }
				$databases += $sapase
				
			}
		}
		else
		{
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "No SAP ASE detected ") *>> $Script:logFile
		}
		
		# MSSQL - Named Instance
		# Detected it from the windows services - MSSQL named instance service "MSSQL$<SID>"
		$MSSQLNamedServices = Get-Service | Where-Object { $_.Name -match "^MSSQL\$[A-Z0-9]{3}$" }
		
		# when mssql databases are found
		if ($MSSQLNamedServices)
		{
			
			# construct the mssql objects
			foreach ($MSSQLNamedService in $MSSQLNamedServices)
			{
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected MSSQL services: " + $MSSQLNamedService.Name) *>> $Script:logFile
				$mssql = New-Object MSSQL
				
				# Set the hostname
				# Must be running on the same computer -> set it to its own hostname
				$dbhost = New-Object Host
				$dbhost.name = $env:computername
				$dbhost.Platform = [Platform]::Windows
				
				$mssql.dbhost = $dbhost
				$mssql.dbtype = [DatabaseType]::mss
				$mssql.dbsid = ($MSSQLNamedService.Name -replace "MSSQL[\$]", "")
				$mssql.service += $MSSQLNamedService
				# get additional services
				# MSSQL Agent "SQLAgent$<SID>"
				$mssql.service += Get-Service | Where-Object { $_.Name -match "^SQLAgent.*" + [regex]::escape($mssql.dbsid) + "$" }
				$databases += $mssql
				
			}
		}
		else
		{
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "No MSSQL detected ") *>> $Script:logFile
		}
		
		# MSSQL - Default Instance
		# Detected it from the windows services - MSSQL Default instance service "MSSQLSERVER"
		$MSSQLDefaultServices = Get-Service | Where-Object { $_.Name -match "^MSSQLSERVER$" }
		
		# when mssql databases are found
		if ($MSSQLDefaultServices)
		{
			
			# construct the mssql objects
			foreach ($MSSQLDefaultService in $MSSQLDefaultServices)
			{
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected MSSQL services: " + $MSSQLDefaultService.Name) *>> $Script:logFile
				$mssql = New-Object MSSQL
				
				# Set the hostname
				# Must be running on the same computer -> set it to its own hostname
				$dbhost = New-Object Host
				$dbhost.name = $env:computername
				$dbhost.Platform = [Platform]::Windows
				
				$mssql.dbhost = $dbhost
				$mssql.dbtype = [DatabaseType]::mss
				$mssql.service += $MSSQLDefaultService
				# get additional services
				# MSSQL Agent "SQLSERVERAGENT"
				$mssql.service += Get-Service | Where-Object { $_.Name -match "^SQLSERVERAGENT$" }
				$databases += $mssql
				
			}
		}
		else
		{
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "No MSSQL default instance detected ") *>> $Script:logFile
		}
		
		# Oracle
		# Detected it from the windows services
		# Oracle database service "OracleService<SID>"
		
		
		$ORACLEServices = Get-Service | Where-Object { $_.Name -match "^OracleService[A-Z0-9]{3}$" }
		
		
		
		# when oracle databases are found
		if ($ORACLEServices)
		{
			
			# construct the oracle objects
			foreach ($ORACLEService in $ORACLEServices)
			{
				Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Detected Oracle services: " + $ORACLEService.Name) *>> $Script:logFile
				$oracledb = New-Object Oracle
				
				# Set the hostname
				# Must be running on the same computer -> set it to its own hostname
				$dbhost = New-Object Host
				$dbhost.name = $env:computername
				$dbhost.Platform = [Platform]::Windows
				$oracledb.dbhost = $dbhost
				
				$oracledb.dbtype = [DatabaseType]::ora
				$oracledb.dbsid = ($ORACLEService.Name -replace "OracleService", "")
				$oracledb.service += $ORACLEService
				# get additional services
				# Oracle VSS write "OracleVssWriter<SID>"
				$oracledb.service += Get-Service | Where-Object { $_.Name -match "^OracleVssWriter" + [regex]::escape($oracledb.dbsid) + "$" }
				# Oracle Oracle Database listener "Oracle<SID>*TNSListener"
				$oracledb.service += Get-Service | Where-Object { $_.Name -match "^Oracle" + [regex]::escape($oracledb.dbsid) + ".*TNSListener$" }
				
				$databases += $oracledb
				
			}
		}
		else
		{
			Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "No Oracle detected ") *>> $Script:logFile
		}
		$this.technicalSystems.AddRange($databases)
	}
}

# Initialize the logging
# return the created logfile
class CustomLogging
{
	
	[System.IO.FileInfo] Initialize()
	{
		# Set Version in registry
		$this.setVersion()
		
		# Create Logging File, if not exist
		# Dir: C:\temp\SAP_Operations\dd_mm_yyyy
		
		$logFileName = ((Get-Date -Format "dd-MM-yyyy_HH-mm_") + $Script:mode + ".log")
		$logDirName = "SAP_Operations_Logs"
		$logDir = ($PSScriptRoot + "\" + $logDirName)
		$logFile = ($logDir + "\" + $logFileName)
		if (!(Test-Path($logDir)))
		{
			# Create directory
			mkdir $logDir
		}
		
		# when there is an existing file
		if (Test-Path($logFile))
		{
			return Get-Item $logFile
		}
		
		return (New-Item $logFile)
	}
	
	[void] setVersion()
	{
		$scriptName = "SAPPatchScript"
		$regPath = "HKLM:\SOFTWARE\UNIT-IT\" + $scriptName
		
		if (!(Test-Path -Path "HKLM:\SOFTWARE\UNIT-IT"))
		{
			New-Item -Path "HKLM:\SOFTWARE" -Name UNIT-IT
		}
		
		if (!(Test-Path -Path ("HKLM:\SOFTWARE\UNIT-IT\" + $scriptName)))
		{
			New-Item -Path "HKLM:\SOFTWARE\UNIT-IT" -Name $scriptName
		}
		
		#Set-ItemProperty -Path $regPath -Name "Version" -Type "String" -Value $global:ScriptVersion -Force
		Set-ItemProperty -Path $regPath -Name "Version" -Type String -Value $global:ScriptVersion -Force
		Set-ItemProperty -Path $regPath -Name "Path" -Type String -Value $PSCommandPath -Force
		
	}
	
	
}


# Beispiel

# Initialize the logging
$logFile = (New-Object CustomLogging).Initialize()

# First Check if there is a delay specified
# Could be the case if the order of the script execution is important

if ($delayInSeconds -gt 0)
{
	Write-Verbose ((Get-Date -Format G) + " | VERBOSE | " + "Script Execution is being delayed by " + $delayInSeconds + " Seconds.") *>> $Script:logFile
	Start-Sleep -Seconds $delayInSeconds
}

$syshelper = New-Object SAPTechnicalSystemHelper
$systems = $syshelper.GetTechnicalSystemsFromDiscovery()


switch ($mode)
{
	"StopALL"
	{
		foreach ($system in $systems)
		{
			# stop the system - the status of operation is returned
			if ($system.Stop())
			{
				# stop the of the sap system is successful
				# only stop the database if the sap system is successfully stopped
				# check if database is of type SAPSYSTEM
				if (($system -is [SAPSystem]) -and (($system.systemType -eq [SystemType]::ABAP) -or ($system.systemType -eq [SystemType]::JAVA)))
				{
					# and DB on the same host as SAP - also stop the database
					if ($system.db.remoteDB -eq $false)
					{
						if (!($system.db.Stop()))
						{
							# implement error return code handling
							# for the calling component
						}
					}
					
				}
			}
			else
			{
				# implement error return code handling
				# for the calling component
			}
			
		}
	}
	"StartALL"
	{
		foreach ($system in $systems)
		{
			# if tech system is SAPSystem of type ABAP or JAVA, then make sure the database ist started first
			if (($system -is [SAPSystem]) -and (($system.systemType -eq [SystemType]::ABAP) -or ($system.systemType -eq [SystemType]::JAVA)))
			{
				# if database is on the same host - first start the database
				# and DB on the same host as SAP - also stop the database
				if ($system.db.remoteDB -eq $false)
				{
					if ($system.db.Start())
					{
						# only start sap system if database is started
						if (!($system.Start()))
						{
							# implement error return code handling
							# for the calling component
						}
					}
					else
					{

						Write-Verbose ((Get-Date -Format G) + " | INFO | Database " + $system.db.dbsid + " cannot be started.") *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | INFO | Skipping the start of SAP System " + $system.sid) *>> $Script:logFile

					}
				}
				else
				{
					# first check if db is running
					# only implemented in hana and oracle
					# try max. 6 hours
					
					$maxWaitTimeInSeconds = 21600
					$currentWaitTimeInS = 0
					While (($system.db.GetStatus() -ne [Status]::Running) -and ($currentWaitTimeInS -le $maxWaitTimeInSeconds))
					{
						Write-Verbose ((Get-Date -Format G) + " | INFO | " + "Database  with sid " + $system.db.dbsid + " for sap system " + $system.sid + " is not started yet - waiting 2 minutes and try again..(" + $currentWaitTimeInS + " Seconds)") *>> $Script:logFile
						Start-Sleep -Seconds 120
						$currentWaitTimeInS += 120
					}
					if ($system.db.GetStatus() -eq [Status]::Running)
					{
						$system.Start()
					}
					else
					{
						Write-Verbose ((Get-Date -Format G) + " | INFO | " + "Remote database of sap system is not running:  " + $system.sid) *>> $Script:logFile
						Write-Verbose ((Get-Date -Format G) + " | INFO | " + "Skipping the start of SAP System " + $system.sid) *>> $Script:logFile

					}
					
				}
				
			}
			# if tech system is not sapystem (eg. standalone DB, CS), then also start this tech system
			else
			{
				$system.Start()
			}
			
		}
	}
}
