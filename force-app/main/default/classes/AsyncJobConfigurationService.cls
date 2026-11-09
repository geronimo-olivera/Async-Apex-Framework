/**
 * File Name   :	AsyncJobConfigurationService.cls
 * Description :	Read-only access to Async_Job_Configuration__mdt, shared by BatchApexHandler and
 *                  QueueableApexHandler. No defaulting logic — that's each handler's job, since a
 *                  missing record is a valid, expected state here.
 *
 *                  Reads with Async_Job_Configuration__mdt.getAll() instead of SOQL: it doesn't use a query,
 *                  and it works in every context, including code running as a standard user in user mode
 *                  (System.runAs in tests), where a SOQL query on a custom metadata type fails.
 **/
public inherited sharing class AsyncJobConfigurationService {

    /** Lets a test supply configuration records, since custom metadata can't be inserted from Apex. */
    @TestVisible
    private static List<Async_Job_Configuration__mdt> configurationsOverride;

    /**
     * Fetches the configuration record for one batch or queueable class, if one exists.
     * @param className API name of the BatchApexHandler or QueueableApexHandler subclass to look up. Case-insensitive.
     * @return the matching Async_Job_Configuration__mdt record, or null if none is configured.
     */
    public static Async_Job_Configuration__mdt getConfigurationByClassName(String className) {
        if (String.isBlank(className)) { return null; }
        List<Async_Job_Configuration__mdt> configurations = configurationsOverride != null
            ? configurationsOverride
            : Async_Job_Configuration__mdt.getAll().values();
        for (Async_Job_Configuration__mdt configuration : configurations) {
            if (className.equalsIgnoreCase(configuration.Class_Name__c)) { return configuration; }
        }
        return null;
    }
}
