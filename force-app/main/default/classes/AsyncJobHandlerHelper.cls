/**
 * File Name   :	AsyncJobHandlerHelper.cls
 * Description :	Logic shared by BatchApexHandler and QueueableApexHandler: resolving a concrete
 *                  subclass's own class name, applying Async_Job_Configuration__mdt's defaults, parsing
 *                  a semicolon-separated recipient list, and sending the failure notification email.
 **/
public inherited sharing class AsyncJobHandlerHelper {

    private static final Integer DEFAULT_MAX_RETRY_ATTEMPTS = 0;
    private static final Integer MAX_ALLOWED_RETRY_ATTEMPTS = 10;

    /**
     * Detects a handler instance's own concrete class name, so it can look up its own configuration
     * without being told its own name.
     * @param handlerInstance Always pass "this", from the base class's own constructor.
     * @return the concrete subclass's API name.
     */
    public static String resolveClassName(Object handlerInstance) {
        return String.valueOf(handlerInstance).split(':')[0];
    }

    /**
     * Applies the framework's defaults on top of a (possibly missing) configuration record.
     * @param config The class's Async_Job_Configuration__mdt record, or null if none exists.
     * @return the resolved settings both handlers need.
     */
    public static Settings resolveSettings(Async_Job_Configuration__mdt config) {
        Settings settings = new Settings();
        settings.isActive = config == null || config.Is_Active__c;
        Integer rawMaxRetryAttempts = config != null && config.Max_Retry_Attempts__c != null ? Integer.valueOf(config.Max_Retry_Attempts__c) : DEFAULT_MAX_RETRY_ATTEMPTS;
        settings.maxRetryAttempts = Math.min(MAX_ALLOWED_RETRY_ATTEMPTS, Math.max(0, rawMaxRetryAttempts));
        settings.sendEmailOnFailure = config != null && config.Send_Email_On_Failure__c;
        settings.notificationEmail = config != null ? config.Notification_Emails__c : null;
        settings.orgWideEmailAddressId = config != null ? config.Org_Wide_Email_Address_Id__c : null;
        return settings;
    }

    /**
     * Emails settings.notificationEmail if settings.sendEmailOnFailure is set. A failure sending the
     * notification itself is logged, not thrown — it shouldn't be able to break the caller's own flow.
     * @param jobClassName The failing class's name, for the log line if sending fails.
     * @param settings The resolved settings; supplies whether to send, who to, and which org-wide address to send from.
     * @param subject Email subject.
     * @param body Email plain-text body.
     */
    public static void sendFailureEmail(String jobClassName, Settings settings, String subject, String body) {
        if (!settings.sendEmailOnFailure) { return; }
        List<String> recipients = parseRecipients(settings.notificationEmail);
        if (recipients.isEmpty()) { return; }
        try {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(recipients);
            email.setSubject(subject);
            email.setPlainTextBody(body);
            if (String.isNotBlank(settings.orgWideEmailAddressId)) {
                email.setOrgWideEmailAddressId(settings.orgWideEmailAddressId);
            }
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Failed to send failure notification for ' + jobClassName + ' to ' + settings.notificationEmail + ': ' + ex.getMessage());
        }
    }

    /**
     * @param rawAddresses Notification_Emails__c's raw value: one address, or several separated by ';'.
     * @return the individual, trimmed addresses, skipping any blank entries. Empty if rawAddresses is blank.
     */
    public static List<String> parseRecipients(String rawAddresses) {
        List<String> recipients = new List<String>();
        if (String.isBlank(rawAddresses)) { return recipients; }
        for (String address : rawAddresses.split(';')) {
            if (String.isNotBlank(address)) {
                recipients.add(address.trim());
            }
        }
        return recipients;
    }

    /**
     * The subset of Async_Job_Configuration__mdt that both BatchApexHandler and QueueableApexHandler need,
     * with the framework's defaults already applied.
     */
    public class Settings {
        public Boolean isActive;
        public Integer maxRetryAttempts;
        public Boolean sendEmailOnFailure;
        public String notificationEmail;
        public String orgWideEmailAddressId;
    }
}
