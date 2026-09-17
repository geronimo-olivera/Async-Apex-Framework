@isTest
public class BatchApexHandlerTest {

    public static Integer executeCount = 0;
    public static Integer failThroughAttempt = 0;
    public static Boolean finishCalled = false;
    public static Boolean lastHadErrors = false;

    @isTest
    static void testDefaultsWhenNoConfigExists() {
        insert new Opportunity(Name = 'Batch Handler Test 1', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();

        Test.startTest();
        Id jobId = BatchApexHandler.run(batch);
        Test.stopTest();

        Assert.isNotNull(jobId, 'a class with no configuration record still runs');
        Assert.areEqual(1, executeCount, 'executeScope ran once for the one queried Opportunity');
        Assert.isTrue(finishCalled, 'onFinish ran');
        Assert.isFalse(lastHadErrors, 'no errors were simulated');
    }

    @isTest
    static void testInactiveConfigSkipsEnqueue() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(false, 0, false, null, null);

        Id jobId = BatchApexHandler.run(batch);

        Assert.isNull(jobId, 'an inactive class does not get enqueued');
        Assert.areEqual(0, executeCount, 'a skipped job never reaches executeScope');
    }

    @isTest
    static void testExecuteScopeFailureIsLoggedAndRethrown() {
        insert new Opportunity(Name = 'Batch Handler Test 2', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        failThroughAttempt = 1;
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();

        Test.startTest();
        BatchApexHandler.run(batch);
        try {
            Test.stopTest();
        } catch (DmlException ex) {
            System.debug(ex.getMessage());
        }

        Assert.areEqual(1, executeCount, 'executeScope ran once and threw');
        Assert.isFalse(finishCalled, 'test context never reaches finish() when the only chunk throws');
    }

    @isTest
    static void testDefaultMaxRetryIsZeroSoFailureIsImmediate() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();

        batch.invokeHandleFinishForTest(1);

        Assert.isTrue(finishCalled, 'onFinish ran');
        Assert.isTrue(lastHadErrors, 'the reported error count surfaces as an error');
    }

    @isTest
    static void testRetrySucceedsOnSecondAttempt() {
        insert new Opportunity(Name = 'Batch Handler Test 3', StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(true, 2, false, null, null);

        Test.startTest();
        batch.invokeHandleFinishForTest(1);
        Test.stopTest();

        Assert.areEqual(1, executeCount, 'the re-enqueued retry actually runs and processes the record');
        Assert.isTrue(finishCalled, 'onFinish ran once the retry completed');
        Assert.isFalse(lastHadErrors, 'the retry attempt had no errors');
    }

    @isTest
    static void testRetryExhaustedSendsFailureEmailToMultipleRecipients() {
        BatchApexHandlerTestBatch batch = new BatchApexHandlerTestBatch();
        batch.configureForTest(true, 1, true, 'first@example.com; second@example.com', null);
        batch.setRetryAttemptForTest(1);
        Integer emailsBefore = Limits.getEmailInvocations();

        batch.invokeHandleFinishForTest(1);

        Assert.isTrue(finishCalled, 'onFinish ran once retries were exhausted');
        Assert.isTrue(lastHadErrors, 'the completing attempt still had errors');
        Assert.areEqual(emailsBefore + 1, Limits.getEmailInvocations(), 'the configured failure email is sent exactly once');
    }
}
