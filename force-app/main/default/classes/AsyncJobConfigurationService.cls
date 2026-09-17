/**
 * File Name   :	AsyncJobConfigurationService.cls
 * Description :	Read-only access to Async_Job_Configuration__mdt, shared by BatchApexHandler and
 *                  QueueableApexHandler. No defaulting logic — that's each handler's job, since a
 *                  missing record is a valid, expected state here.
 **/
public inherited sharing class AsyncJobConfigurationService {

    /**
     * Fetches the configuration record for one batch or queueable class, if one exists.
     * @param className API name of the BatchApexHandler or QueueableApexHandler subclass to look up.
     * @return the matching Async_Job_Configuration__mdt record, or null if none is configured.
     */
    public static Async_Job_Configuration__mdt getConfigurationByClassName(String className) {
        List<Async_Job_Configuration__mdt> configs = [
            SELECT Class_Name__c,
                Job_Type__c,
                Batch_Size__c,
                Is_Active__c,
                Max_Retry_Attempts__c,
                Send_Email_On_Failure__c,
                Notification_Emails__c,
                Org_Wide_Email_Address_Id__c
            FROM Async_Job_Configuration__mdt
            WHERE Class_Name__c = :className
            LIMIT 1
        ];
        return configs.isEmpty() ? null : configs[0];
    }
}
