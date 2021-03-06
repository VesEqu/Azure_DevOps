param(
	[parameter(Mandatory = $true)]
	[String]$adminUserName,
	[parameter(Mandatory = $true)]
	[String]$adminPWD,
	[parameter(Mandatory = $true)]
	[String]$baseURL,
	[parameter(Mandatory = $true)]
	[String]$wspPath,
	[parameter(Mandatory = $true)]
	[Int]$userCount
)

Add-PSSnapin "Microsoft.SharePoint.Powershell"
Import-Module LogToFile

$Domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
$adminUserAlias = "$($Domain)\$($adminUserName)"

# Create managed account for admin user
LogToFile -Message "Creating SharePoint managed account for admin user"
$secpasswd = ConvertTo-SecureString $adminPWD -AsPlainText -Force
$creds = New-Object System.Management.Automation.PSCredential ($adminUserAlias, $secpasswd)
New-SPManagedAccount -Credential $creds
LogToFile -Message "Done creating SharePoint managed account for admin user"

# Start the user profile service
LogToFile -Message "Starting the SharePoint user profile service"
$UserProfileServiceInstance = Get-SPServiceInstance| Where-Object { $_.TypeName -eq "User Profile Service" }
if (-not($UserProfileServiceInstance))
{ 
	LogToFile -Message "ERROR:Did not find an instance of the user profile service"
	throw [System.Exception] "Did not find an instance of the user profile service" 
}
if ($UserProfileServiceInstance.Status -eq "Disabled")
{
	Start-SPServiceInstance -Identity $UserProfileServiceInstance
	if (-not($?))
	{ 
		LogToFile -Message "ERROR:User profile service failed to start"
		throw [System.Exception] "User profile service failed to start" 
	}
}
$retryCount = 0
while (-not($UserProfileServiceInstance.Status -eq "Online"))
{
	if($retryCount -ge 60)
	{
		LogToFile -Message "ERROR:Starting user profile service has timed out"
		throw [System.Exception] "Starting user profile service has timed out" 
	}
	$UserProfileServiceInstance = Get-SPServiceInstance| Where-Object { $_.TypeName -eq "User Profile Service" }
	LogToFile -Message "Wating for user profile service to start"
	Start-Sleep -Seconds 5
	$retryCount++
}
LogToFile -Message "User profile service has started"

# Install the SP load test preparation solution file
LogToFile -Message "Installing load test initialization wsp"
Add-SPSolution -LiteralPath $wspPath
Install-SPSolution -Identity LoadGenerationSharePointSolution.wsp –GACDeployment
$solution = Get-SPSolution -Identity LoadGenerationSharePointSolution.wsp
while(-not($solution.Deployed))
{
	# Wait for the solution to be installed, for the solution path to become available
	LogToFile -Message "Waiting for the wsp to be deployed..."
	Start-Sleep -Seconds 5
	$solution = Get-SPSolution -Identity LoadGenerationSharePointSolution.wsp
}
LogToFile -Message "Done installing load test initialization wsp"

$ltSolPath = "$env:SystemDrive\Program Files\Common Files\microsoft shared\Web Server Extensions\15\LoadGeneration"
$ltConfigFileName = "loadtest.config"
$ltConfigFilePath = Join-Path $ltSolPath $ltConfigFileName

LogToFile -Message "Setting the number of users on the init config file"
# Safe overwrite of default number of users with the desired number of users
$configXML = [System.Xml.XmlDocument] (Get-Content -Path $ltConfigFilePath)
$userCountXpath = "/LoadTestConfig/UserCount"
$node = $configXML.SelectNodes($userCountXpath)
$node[0].InnerText = $userCount
$configXML.Save($ltConfigFilePath)
LogToFile -Message "Done setting the number of users"

pushd $ltSolPath
.\Initialize-SPFarmLoadTest.ps1 $baseURL $userCount
popd
LogToFile -Message "Done executing load test init script"
