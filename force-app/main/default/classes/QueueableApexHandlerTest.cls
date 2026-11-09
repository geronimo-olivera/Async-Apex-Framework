@isTest
private class QueueableApexHandlerTest {

    static Integer executeCount = 0;
    static Integer failThroughAttempt = 0;
    static Boolean insertBeforeFailing = false;
    static Boolean finishCalled = false;
    static Boolean lastHadErrors = false;

    static User createStandardUser() {
        List<Profile> profiles = [
            SELECT Id, Name FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND PermissionsModifyAllData = false
            AND PermissionsViewAllData = false AND PermissionsCustomizeApplication = false
            ORDER BY Name
        ];
        Profile chosen = profiles[0];
        for (Profile candidate : profiles) {
            if (candidate.Name == 'Standard User' || candidate.Name == 'Usuario estándar') { chosen = candidate; break; }
        }
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User user = new User(
            ProfileId = chosen.Id, FirstName = 'Standard', LastName = 'Tester', Alias = 'stdtst',
            Email = 'standard.tester@example.com', Username = 'standard.tester.' + unique + '@example.com',
            TimeZoneSidKey = 'America/Montevideo', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert user;
        return user;
    }

    @isTest
    static void testDefaultsWhenNoConfigExists() {
        TestQueueable job = new TestQueueable();

        Test.startTest();
        Id jobId = QueueableApexHandler.run(job);
        Test.stopTest();

        Assert.isNotNull(jobId, 'a class with no configuration record still runs');
        Assert.areEqual(1, executeCount, 'executeJob ran once');
        Assert.isTrue(finishCalled, 'the finalizer called onFinish');
        Assert.isFalse(lastHadErrors, 'no errors were simulated');
        Assert.areEqual('Completed', [SELECT Status FROM AsyncApexJob WHERE Id = :jobId].Status, 'a successful job shows as Completed');
    }

    @isTest
    static void testInactiveConfigSkipsEnqueue() {
        TestQueueable job = new TestQueueable();
        job.configureForTest(false, 0, false, null, null);

        Id jobId = QueueableApexHandler.run(job);

        Assert.isNull(jobId, 'an inactive class does not get enqueued');
        Assert.areEqual(0, executeCount, 'a skipped job never reaches executeJob');
    }

    @isTest
    static void testFailureIsNotSwallowed() {
        failThroughAttempt = 1;
        TestQueueable job = new TestQueueable();
        Boolean surfaced = false;

        Test.startTest();
        QueueableApexHandler.run(job);
        try {
            Test.stopTest();
        } catch (DmlException ex) {
            surfaced = ex.getMessage() == 'Simulated failure.';
        }

        // The old version caught the exception inside execute(), which kept the half-done work and showed the job
        // as Completed. Now it propagates: Salesforce rolls the job back, marks it Failed, and the finalizer
        // (covered by testFinalizerReadsTheJobResult) retries or reports it. In a test the exception reaches
        // stopTest instead; the rollback and the Failed status are verified end to end in a scratch org.
        Assert.isTrue(surfaced, 'the job exception is no longer swallowed by execute()');
        Assert.areEqual(1, executeCount, 'the job ran once');
    }

    @isTest
    static void testFailureWithRetriesLeftEnqueuesAnotherAttempt() {
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 2, false, null, null);

        job.handleCompletion(true, 'Simulated failure.');

        Assert.areEqual(1, job.getRetryAttempt(), 'the retry counter moved on');
        Assert.areEqual(1, Limits.getQueueableJobs(), 'the next attempt was enqueued');
        Assert.isFalse(finishCalled, 'onFinish waits for the attempt that completes');
    }

    @isTest
    static void testRetryCanBeDelayed() {
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 1, false, null, null);
        job.setRetryDelayForTest(5);

        job.handleCompletion(true, 'External system unavailable.');

        Assert.areEqual(1, Limits.getQueueableJobs(), 'the delayed retry was enqueued');
    }

    @isTest
    static void testRetryExhaustedSendsFailureEmailToMultipleRecipients() {
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 1, true, 'first@example.com; second@example.com', null);
        job.setRetryAttemptForTest(1);
        Integer emailsBefore = Limits.getEmailInvocations();

        job.handleCompletion(true, 'Simulated failure.');

        Assert.isTrue(finishCalled, 'onFinish ran once retries were exhausted');
        Assert.isTrue(lastHadErrors, 'the completing attempt still had errors');
        Assert.areEqual(emailsBefore + 1, Limits.getEmailInvocations(), 'the configured failure email is sent exactly once');
        Assert.areEqual(0, Limits.getQueueableJobs(), 'no further attempt is enqueued');
    }

    @isTest
    static void testInvalidNotificationAddressDoesNotBreakProcessing() {
        TestQueueable job = new TestQueueable();
        job.configureForTest(true, 0, true, 'not-an-email', '0D8000000000000AAA');

        job.handleCompletion(true, 'Simulated failure.');

        Assert.isTrue(finishCalled, 'onFinish still ran even though the notification email is malformed');
        Assert.isTrue(lastHadErrors, 'the failure is still recorded correctly');
    }

    @isTest
    static void testFinalizerReadsTheJobResult() {
        TestQueueable job = new TestQueueable();
        QueueableApexHandler.CompletionFinalizer finalizer = new QueueableApexHandler.CompletionFinalizer(job);

        finalizer.execute(new FakeFinalizerContext(System.ParentJobResult.SUCCESS, null));
        Assert.isTrue(finishCalled && !lastHadErrors, 'a successful attempt finishes without errors');

        finalizer.execute(new FakeFinalizerContext(System.ParentJobResult.UNHANDLED_EXCEPTION, new DmlException('Simulated failure.')));
        Assert.isTrue(lastHadErrors, 'an unhandled exception finishes with errors');
    }

    @isTest
    static void testTooManyJobsInOneTransactionFailsWithAClearMessage() {
        Integer limitJobs = Limits.getLimitQueueableJobs();
        for (Integer i = 0; i < limitJobs; i++) {
            QueueableApexHandler.run(new TestQueueable());
        }
        try {
            QueueableApexHandler.run(new TestQueueable());
            Assert.fail('enqueueing past the limit should fail');
        } catch (AsyncJobHandlerBase.AsyncJobException ex) {
            Assert.isTrue(ex.getMessage().contains('one job'), 'the message says how to fix it: ' + ex.getMessage());
        }
    }

    @isTest
    static void testConfigurationIsFoundByClassNameAndJobName() {
        String className = AsyncJobHandlerHelper.resolveClassName(new TestQueueable());
        AsyncJobConfigurationService.configurationsOverride = new List<Async_Job_Configuration__mdt>{
            new Async_Job_Configuration__mdt(Class_Name__c = className.toUpperCase(), Is_Active__c = false, Max_Retry_Attempts__c = 3),
            new Async_Job_Configuration__mdt(Class_Name__c = 'Custom_Job_Name', Is_Active__c = false)
        };

        Assert.isNull(QueueableApexHandler.run(new TestQueueable()), 'the record matching the class name, in any case, applies');
        Assert.isNull(QueueableApexHandler.run(new NamedQueueable()), 'a job that overrides getJobName is matched by that name');
        Assert.isNull(AsyncJobConfigurationService.getConfigurationByClassName(''), 'a blank name matches nothing');
        Assert.isNull(AsyncJobConfigurationService.getConfigurationByClassName('NoSuchJob'), 'an unknown name matches nothing');
    }

    @isTest
    static void testStandardUserCanRunJobs() {
        User standardUser = createStandardUser();
        System.runAs(standardUser) {
            Test.startTest();
            Id jobId = QueueableApexHandler.run(new TestQueueable());
            Test.stopTest();

            Assert.isNotNull(jobId, 'a non-admin user can start a job: reading the configuration needs no permission');
        }
        Assert.areEqual(1, executeCount, 'the job ran');
        Assert.isFalse(lastHadErrors, 'without errors');
    }

    public class TestQueueable extends QueueableApexHandler {

        void configureForTest(Boolean isActive, Integer maxRetryAttempts, Boolean sendEmailOnFailure, String notificationEmail, String orgWideEmailAddressId) {
            settings.isActive = isActive;
            settings.maxRetryAttempts = maxRetryAttempts;
            settings.sendEmailOnFailure = sendEmailOnFailure;
            settings.notificationEmail = notificationEmail;
            settings.orgWideEmailAddressId = orgWideEmailAddressId;
        }

        void setRetryAttemptForTest(Integer value) {
            retryAttempt = value;
        }

        void setRetryDelayForTest(Integer minutes) {
            settings.retryDelayMinutes = minutes;
        }

        Integer getRetryAttempt() {
            return retryAttempt;
        }

        protected override void executeJob() {
            executeCount++;
            if (insertBeforeFailing) {
                insert new Account(Name = 'Saved before the failure');
            }
            if (executeCount <= failThroughAttempt) {
                throw new DmlException('Simulated failure.');
            }
        }

        protected override void onFinish(Boolean hadErrors) {
            finishCalled = true;
            lastHadErrors = hadErrors;
        }
    }

    public class NamedQueueable extends QueueableApexHandler {
        protected override String getJobName() {
            return 'Custom_Job_Name';
        }

        protected override void executeJob() {}
    }

    public class FakeFinalizerContext implements System.FinalizerContext {
        private System.ParentJobResult result;
        private Exception error;

        FakeFinalizerContext(System.ParentJobResult result, Exception error) {
            this.result = result;
            this.error = error;
        }

        public Id getAsyncApexJobId() { return null; }
        public String getRequestId() { return null; }
        public System.ParentJobResult getResult() { return result; }
        public Exception getException() { return error; }
    }
}
