@isTest
public class BatchApexHandlerTestBatch extends BatchApexHandler {

    public void configureForTest(Boolean isActive, Integer maxRetryAttempts, Boolean sendEmailOnFailure, String notificationEmail, String orgWideEmailAddressId) {
        settings.isActive = isActive;
        settings.maxRetryAttempts = maxRetryAttempts;
        settings.sendEmailOnFailure = sendEmailOnFailure;
        settings.notificationEmail = notificationEmail;
        settings.orgWideEmailAddressId = orgWideEmailAddressId;
    }

    public void setRetryAttemptForTest(Integer value) {
        retryAttempt = value;
    }

    public void invokeHandleFinishForTest(Integer numberOfErrors) {
        handleFinish(numberOfErrors);
    }

    protected override Database.QueryLocator getQueryLocator() {
        return Database.getQueryLocator([SELECT Id FROM Opportunity]);
    }

    protected override void executeScope(List<SObject> scope) {
        BatchApexHandlerTest.executeCount++;
        if (BatchApexHandlerTest.executeCount <= BatchApexHandlerTest.failThroughAttempt) {
            throw new DmlException('Simulated failure.');
        }
    }

    protected override void onFinish(Boolean hadErrors) {
        BatchApexHandlerTest.finishCalled = true;
        BatchApexHandlerTest.lastHadErrors = hadErrors;
    }
}
