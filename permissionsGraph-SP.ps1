# Assign API permission to a Managed Identity

$TenantID = "<your tenantid>"
$GraphAppId = "00000003-0000-0000-c000-000000000000"
$DisplayNameMI = "<name of Logic App>"
$GraphPermission = "AuditLog.Read.All"

Connect-MgGraph -Scopes Application.Read.All,AppRoleAssignment.ReadWrite.All -TenantId $TenantID

$IdMI = Get-MgServicePrincipal -Filter "DisplayName eq '$DisplayNameMI'"

## Get assigned roles
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $IdMI.Id

## Get Graph roles
$GraphServicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'"
$AppRole = $GraphServicePrincipal.AppRoles | Where-Object {$_.Value -eq $GraphPermission -and $_.AllowedMemberTypes -contains "Application"}

$AppRole

$params = @{
	principalId = $IdMI.Id
	resourceId = $GraphAppId
    appRoleId = $($AppRole.Id)
}

## Add permission to Managed Identity
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $IdMI.Id -ResourceId $GraphServicePrincipal.Id -PrincipalId $IdMI.Id -AppRoleId $AppRole.Id

## Get assigned roles
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $IdMI.Id